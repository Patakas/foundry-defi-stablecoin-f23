// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/Oraclelib/sol";
/**
 * @title DSCEngine
 * @author Patrick Collins
 * 
 * This system is designed to be as minimal as possible, and have the tokens maintain 
 * a 1 token == 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral 
 * - Dollar Pegged 
 * - Algorithmically stable 
 * 
 * It is simillar to DAI if DAI had no governance, no fees, and was only backed by WETH
 and WBTC.
 * Our DSC system should always be "overcollateralized". At no point, should the value 
 of all collateral <= the $ backed value of all the DSC.
 * @notice This contract is the core of the DSC system. It handles all the logic for minting
 and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is very loosely based on DAI on the makerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ////////////////////////
    //       Errors      //
    //////////////////////
    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////////
    //       Type     /////
    //////////////////////

    using OracleLib for AggregatorV3Interface;

    //////////////////////
    // State Variables //
    ////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
    private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens; 

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means a 10% bonus


    DecentralizedStableCoin private immutable i_dsc;
    ////////////////////
    //     Events    //
    //////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed
    amount); 
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo,
    address indexed token, uint256 amount);

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions //
    ///////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);

    }

    ///////////////////////
    // External Functions //
    ///////////////////////
    
    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral,uint256 amountDscToMint)
     external {
        depositCollateral(tokenCollateralAddress,amountCollateral);
        mintDsc(amountDscToMint);
     }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled 
    // DRY dont repeat yourself
    // CEI checks, effects, interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
     
    {    
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
 }

    /*
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender,amountDscToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // i dont think this will ever hit 
    }
        // if we do start near undercollarization, we need to liquidate positions
        // 100 eth backing $50 DSC
        // 20 ETH back $50 DSC <- dsc isnt worth 1 $ !!!!
        // 75 backing 50 dsc
        // Liquitator tacking 75$ backing and burns off the $50 DSC 
    
    // if someone is almost undercollateralized, we will pay you to liquidate them!

    /*



    */
    function liquadate(address collateral, address user, uint256 debtToCover) 
    external 
    moreThanZero(debtToCover) 
    nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(user);
        if ( startingHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION ;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // we need to burn the dsc now
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);


    }

    function getHealthFactor() external view {}

    ////////////////////////////////////////
    // Private & Internal View Functions //
    //////////////////////////////////////

/*
* @dev Low-level internal function, do not call unless the function calling it is 
* checking for health factors being broken 
*/
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private{
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn); 
    }

    function _redeemCollateral (address from, address to,
    address tokenCollateralAddress, uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success){
            revert DSCEngine__TransferFailed();
        }

    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * Returns how close to liquidation a user is
     * if a user goes below 1, they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
            uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION ;
       // return (collateralValueInUsd / totalDscMinted); // 150 / 100
            return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    // 1. check health factor (do they have enough collateral?)
    // 2. if not, revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreaksHealthFactor (userHealthFactor);
        }
    }



    ////////////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 amountInWei) public view returns 
    (uint256){
        // price of Eth (token)
        // $/ETH ETH??
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return (amountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);

    }



    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd)
    {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value. 
        for(uint256 i=0; i<s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token,amount);
        }
        return totalCollateralValueInUsd;
    }
    function getUsdValue(address token, uint256 amount) public view returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        // 1 ETH = 1000$
        // The returned value will be 1000 * 1e8
        return ((uint256(answer) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(1000 * 1e8 * 1e18)
    }
    function getCollateralTokens() external view returns (address[] memory ){
        return s_collateralTokens;
    }
    function getCollateralValueOfUser(address user, address token) external view returns 
    (uint256 s_collateralDeposited){
        return s_collateralDeposited[user][token];
    }
}
