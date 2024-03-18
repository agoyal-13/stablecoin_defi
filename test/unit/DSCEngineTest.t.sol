// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "@forge-std/Test.sol";
import {DSCEngine} from "../../src/contracts/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/contracts/DecentralizedStableCoin.sol";
// import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC public deployer;
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant REDEEM_COLLATERAL_AMOUNT = 3 ether;
    uint256 public constant AMOUNT_TO_MINT = 10 ether;
    uint256 public constant AMOUNT_TO_BURN = 3 ether;
    uint256 public constant PRICE_FEED_WETH_USD = 2000;
    uint256 public constant PRICE_FEED_WBTC_USD = 1000;

    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();
        console.log("msg.sender address :", USER);
        console.log("owner of dsc is :", dsc.owner());

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        console.log("balance at setup", ERC20Mock(weth).balanceOf(USER));
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = ethAmount * 2000;
        uint256 priceInUsd = dscEngine.getTokenUsdValue(weth, ethAmount);
        assertEq(expectedUsd, priceInUsd);
    }

    function testRevertIfTokenLengthDoesNotMatchPriceFeed() public {
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokensFromUsdValue() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedTokenValue = 0.05 ether;
        uint256 actualTokenValue = dscEngine.getTokensFromUsdValue(weth, usdAmount);

        assertEq(actualTokenValue, expectedTokenValue);
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        console.log("balance is :", dsc.balanceOf(USER));
        ERC20Mock(weth).approve(address(dscEngine), STARTING_ERC20_BALANCE);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        console.log("deposited amt:", dscEngine.getUserCollateralDeposited(weth));
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedDscMinted = 0;
        uint256 actualTokensValueDeposited = dscEngine.getTokensFromUsdValue(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(AMOUNT_COLLATERAL, actualTokensValueDeposited);
    }

    modifier depositedCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testMintDSC() public depositedCollateralAndMintDsc {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, AMOUNT_TO_MINT);
        assertEq(collateralValueInUsd, AMOUNT_COLLATERAL * PRICE_FEED_WETH_USD);
    }

    function testGetHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        dscEngine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();
        uint256 actualHealthfactor = dscEngine.getHealthFactor(USER);
        console.log("actualHealthfactor::", actualHealthfactor);
        uint256 expectedHealthfactor = 100;
        assertEq(actualHealthfactor, expectedHealthfactor);
    }

    function testRevertHealthFactorBroken() public depositedCollateral {
        uint256 healthFactor = 0;
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBroken.selector, healthFactor));
        dscEngine.mintDSC(10000 ether);
        vm.stopPrank();
    }

    function testRedeemCollateral() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, REDEEM_COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, REDEEM_COLLATERAL_AMOUNT);
        vm.stopPrank();
        (, uint256 collateralValueInUsdAfterRedemption) = dscEngine.getAccountInformation(USER);
        console.log("collateralValueInUsdAfterRedemption:", collateralValueInUsdAfterRedemption);
        uint256 actualTokenValue = dscEngine.getTokensFromUsdValue(weth, collateralValueInUsdAfterRedemption);
        uint256 expectedToken = AMOUNT_COLLATERAL - REDEEM_COLLATERAL_AMOUNT;

        assertEq(actualTokenValue, expectedToken);
    }

    function testRevertAmountNotGreaterThanZeroDuringBurnDsc() public {
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NeedsMoreThanZero.selector));
        dscEngine.burnDSC(0);
    }

    function testBurnDsc() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_BURN);
        dscEngine.burnDSC(AMOUNT_TO_BURN);
        vm.stopPrank();
        (uint256 dscLeft,) = dscEngine.getAccountInformation(USER);
        uint256 expectedDSC = AMOUNT_TO_MINT - AMOUNT_TO_BURN;
        uint256 dscBalanceOfUser = dsc.balanceOf(USER);
        assertEq(dscLeft, expectedDSC);
        assertEq(dscLeft, dscBalanceOfUser);
    }

    function testRevertCantBurnMoreDscThanUserHas() public depositedCollateralAndMintDsc {
        uint256 burnDscAmount = 2 * AMOUNT_COLLATERAL;
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.burnDSC(burnDscAmount);
        vm.stopPrank();
    }

    function testRevertIfHealthFactorIsOk() public depositedCollateralAndMintDsc {
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorOk.selector));
        dscEngine.liquidate(weth, LIQUIDATOR, AMOUNT_COLLATERAL);
    }

    function testLiquidationOfCollateral() public depositedCollateral {
        vm.prank(USER);
        dscEngine.mintDSC(14000 ether);
        vm.prank(LIQUIDATOR);
        dscEngine.liquidate(weth, USER, AMOUNT_COLLATERAL);
    }

    function testRevertHealthFactorNotImprovedOnLiquidation() public {
        // 10 * 18 e17 = 18 e18
        // 100 e18 dsc coins
        // health factor = 18 e18 * 50 *1e18 / 100 = 9 e36
        // 9 e36 / 100 e18 = 9 e16 health factor
        // for liquidator
        //  16e18 * 1e18 / 18 e17 = 8.88 e18 tokens value
        // bonus 8.88e18 * 10 / 100 = 8.88e17
        // total value = 88.88e17 + 8.88e17 = 97.76e17
        // user balance 10e18 - 9.776e18 = 2,22,22,22,22,22,22,22,224
        // liquidator balance =  1e18 + 9.776e18 = 10.776e18
        uint256 USER_DSC_AMOUNT_TO_MINT = 100 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, USER_DSC_AMOUNT_TO_MINT);
        vm.stopPrank();

        // Arrange - Liquidator
        uint256 collateralToCover = 1 ether;
        uint256 amountToMint = 100 ether;
        uint256 debtToCover = 16 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), debtToCover);

        (uint256 dscBalance, uint256 collateralBalance) = dscEngine.getAccountInformation(LIQUIDATOR);
        console.log("LIQUIDATOR collateralBalance:", collateralBalance);
        console.log("LIQUIDATOR balance:", dscBalance);

        (uint256 dscUserBalance, uint256 collateralUserBalance) = dscEngine.getAccountInformation(USER);
        console.log("user collateralBalance:", collateralUserBalance);
        console.log("user balance:", dscUserBalance);
        // Act

        int256 ethUsdUpdatedPrice = 18e7; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testBalancesOnLiquidation() public {
        // 10 * 18 e17 = 18 e18
        // 100 e18 dsc coins
        // health factor = 18 e18 * 50 *1e18 / 100 = 9 e36
        // 9 e36 / 100 e18 = 9 e16 health factor
        // for liquidator
        //  40e18 * 1e18 / 18 e17 = 22.88 e18 tokens value
        // bonus 22.88e18 * 10 / 100 = 2.22e18
        // total value = 22.88e18 + 2.22e18 = 25.1e18
        // user balance 10e18 - 9.776e18 = 2,22,22,22,22,22,22,22,224
        // liquidator balance =  1e18 + 9.776e18 = 10.776e18
        uint256 USER_DSC_AMOUNT_TO_MINT = 100 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, USER_DSC_AMOUNT_TO_MINT);
        vm.stopPrank();

        // Arrange - Liquidator
        uint256 collateralToCover = 1 ether;
        uint256 amountToMint = 100 ether;
        uint256 debtToCover = 40 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), debtToCover);

        (uint256 dscBalance, uint256 collateralBalance) = dscEngine.getAccountInformation(LIQUIDATOR);
        console.log("LIQUIDATOR collateralBalance:", collateralBalance);
        console.log("LIQUIDATOR balance:", dscBalance);

        (uint256 dscUserBalance, uint256 collateralUserBalance) = dscEngine.getAccountInformation(USER);
        console.log("user collateralBalance:", collateralUserBalance);
        console.log("user balance:", dscUserBalance);
        // Act

        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        uint256 expectedUserDscBalance = USER_DSC_AMOUNT_TO_MINT - debtToCover;
        (uint256 dscBalanceOfUser, uint256 userCollateralBalance) = dscEngine.getAccountInformation(USER);
        uint256 expectedCollateralUserBalance = 136000000000000000008;
        console.log("userCollateralBalance:--", userCollateralBalance);

        assertEq(dscBalanceOfUser, expectedUserDscBalance);
        assertEq(userCollateralBalance, expectedCollateralUserBalance);
    }
}
