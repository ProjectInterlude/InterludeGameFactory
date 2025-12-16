// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOnchainGameEarnings
 * @dev Interface for the earnings and fund management contract
 */
interface IOnchainGameEarnings {
    
    // Core earnings functions
    function updatePlayerStats(uint256 gameID, address player, uint256 points) external;
    function payEarnings(uint256 gameID, address player, uint256 amount, uint256 score) external;
    function payJackpot(uint256 gameID, address winner) external returns (uint256);
    function recordBetAndCheckBalance(uint256 gameID, address player, uint256 betAmount, uint256 maxWinMultiplier) external payable;
    
    // View functions
    function getPendingEarnings(uint256 gameID, address player) external view returns (uint256);
    function getTotalEarnings(uint256 gameID, address player) external view returns (uint256);
    function getAccumulatedJackpot(uint256 gameID) external view returns (uint256);
    function getJackpotPayoutAmount(uint256 gameID) external view returns (uint256);
    function getGameTotalBets(uint256 gameID) external view returns (uint256);
    function getGameTotalRewards(uint256 gameID) external view returns (uint256);
    
}
