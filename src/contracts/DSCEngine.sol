// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {PriceFeedLib} from "../libraries/PriceFeedLib.sol";
import {console} from "@forge-std/console.sol";

/**
 * @notice this contract is core of the DSC system. IT handles all the logic for mining and redeeming DSC,
 * as well as depositing and withdrawal of the collaterals.
 * this contract is very lossely based on the MakerDAO (DAI) system.
 *
 * Our DSC system always be collateral and never the collateral val <= all DSC coins
 * if it less down then we have to liquidate the DSC as system can't be never under collateral.
 */
contract DSCEngine is ReentrancyGuard {
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__CollateralDepositedIsLessThanRedeemed();
    error DSCEngine__HealthFactorIsBroken(uint256 _healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    using PriceFeedLib for AggregatorV3Interface;

    event CollateralRedeemed(address indexed user, address indexed to, address indexed token, uint256 value);

    mapping(address token => address priceFeed) private s_priceFeeds;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => mapping(address collateralToken => uint256 collateralAmount)) private
        s_userCollateralDeposited;
    mapping(address user => uint256 dscMinted) private s_userDscMinted;
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;

    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS_PERCENT = 10;

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory _tokenAddress, address[] memory _priceFeedAddress, address _dscAddress) {
        // console.log("_dscAddress ::", _dscAddress);

        if (_tokenAddress.length != _priceFeedAddress.length) {
            revert DSCEngine__TokenAddressAndPriceFeedMustBeSameLength();
        }
        for (uint256 i = 0; i < _tokenAddress.length; i++) {
            s_priceFeeds[_tokenAddress[i]] = _priceFeedAddress[i];
            s_collateralTokens.push(_tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    function depositCollateralAndMintDSC(
        address _tokenCollateralAddress,
        uint256 _collateralAmount,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _collateralAmount);
        mintDSC(_amountDscToMint);
    }

    /**
     * _tokenCollateralAddress is address of basically an ERC20 fungible token and _collateralAmount is the number of tokens of that type to be staked.
     * we will transfer of that finite number of tokens as collateral to get the stable coins which has market value and they are stable.
     * Our real estate is changing and we convert it into an ERC20 tokens and stake some of them here in this method to get some DSC.
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _collateralAmount)
        public
        moreThanZero(_collateralAmount)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_userCollateralDeposited[msg.sender][_tokenCollateralAddress] += _collateralAmount;
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _collateralAmount);
        console.log("collateral transferred status :", success);
        console.log("dsc engine balance after transfer--------------:", address(this).balance);
        if (!success) {
            console.log("collateral deposited :", _collateralAmount);
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(
        address _tokenCollateralAddress,
        uint256 _collateralAmount,
        uint256 _dscAmountToBurn
    ) external {
        burnDSC(_dscAmountToBurn);
        redeemCollateral(_tokenCollateralAddress, _collateralAmount);
    }

    function redeemCollateral(address _tokenCollateralAddress, uint256 _collateralAmount)
        public
        moreThanZero(_collateralAmount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDSC(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_userDscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
        console.log('amount minted successfully:',_amountDscToMint);
    }

    function burnDSC(uint256 _amount) public moreThanZero(_amount) {
        _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If someone is almost undercollateralized we will pay to liquidate them but this function will work when
    // we have some overcollateral only otherwise nobody will burn their DSC in exchange of lower ETH.
    // this method will give 10% incentive to the user who liquidate their stable coins for ETH.
    function liquidate(address _collateralToken, address _user, uint256 _debtToRecover)
        public
        moreThanZero(_debtToRecover)
        nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(_user);
        console.log("startingHealthFactor:--", startingHealthFactor);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 totalAmountFromDebtCovered = getTokensFromUsdValue(_collateralToken, _debtToRecover);
        console.log("totalAmountFromDebtCovered:--", totalAmountFromDebtCovered);
        uint256 bonus = (totalAmountFromDebtCovered * LIQUIDATION_BONUS_PERCENT) / 100;
        console.log("bonus:--", bonus);
        uint256 totalLiquidationValue = totalAmountFromDebtCovered + bonus;
        console.log("totalLiquidationValue:--", totalLiquidationValue);

        _redeemCollateral(_user, msg.sender, _collateralToken, totalLiquidationValue);
        _burnDsc(_debtToRecover, _user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(_user);
        console.log("endingHealthFactor:--", endingHealthFactor);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(_user);
    }

    function _redeemCollateral(address _from, address _to, address _tokenCollateralAddress, uint256 _collateralAmount)
        internal
    {
        console.log("collateral depsoited earlier :", s_userCollateralDeposited[_from][_tokenCollateralAddress]);
        s_userCollateralDeposited[_from][_tokenCollateralAddress] -= _collateralAmount;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _collateralAmount);

        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 _amountDscToBurn, address onBehalfOf, address _from) internal {
        s_userDscMinted[onBehalfOf] -= _amountDscToBurn;
        console.log("allowance after approve:", i_dsc.allowance(_from, address(this)));
        bool success = i_dsc.transferFrom(_from, address(this), _amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountDscToBurn); // this will decrease the debt so the next line will never be happened
    }

    function _healthFactor(address _user) private view returns (uint256) {
        return _calculateHealthFactor(_user);
    }

    function _calculateHealthFactor(address _user) internal view returns (uint256) {
        (uint256 totalAmountOfDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(_user);
        console.log("totalAmountOfDscMinted:", totalAmountOfDscMinted);
        console.log("totalCollateralValueInUsd:", totalCollateralValueInUsd);
        if (totalAmountOfDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold / totalAmountOfDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 factor = _healthFactor(_user);
        console.log("facotr is :", factor);
        if (factor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBroken(factor);
        }
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 _totalDscMinted, uint256 _collateralValueInUsd)
    {
        _totalDscMinted = s_userDscMinted[_user];
        _collateralValueInUsd = getAccountCollateralValue(_user);
        return (_totalDscMinted, _collateralValueInUsd);
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 _totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_userCollateralDeposited[_user][token];
            _totalCollateralValueInUsd += getTokenUsdValue(token, amount);
        }
        return _totalCollateralValueInUsd;
    }

    function getTokenUsdValue(address _token, uint256 _amountOfToken) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.staleCheckPriceFeedAggregatorData();
        console.log("Price in getUsdValue from pricefeed:", uint256(price));
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amountOfToken) / PRECISION;
    }

    function getTokensFromUsdValue(address _collateralToken, uint256 _usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_collateralToken]);
        (, int256 price,,,) = priceFeed.staleCheckPriceFeedAggregatorData();
        console.log("price in getTokensFromUsdValue", uint256(price));
        return (_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getHealthFactor(address _user) public view returns (uint256) {
        return _healthFactor(_user);
    }

    function getUserCollateralDeposited(address _tokenAddress) external view returns (uint256) {
        return s_userCollateralDeposited[msg.sender][_tokenAddress];
    }

    function getAccountInformation(address user) external view returns (uint256, uint256) {
        return _getAccountInformation(user);
    }
}
