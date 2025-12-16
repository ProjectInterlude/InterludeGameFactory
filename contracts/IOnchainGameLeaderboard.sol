// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOnchainGameLeaderboard
 * @dev Interface for the leaderboard, statistics, and jackpot management contract
 */
interface IOnchainGameLeaderboard {
    
    // Jackpot structures
    struct PlayerScore {
        address player;
        uint256 score;
    }

    // Events
    event PlayerNameSet(address indexed player, string name);
    event ScoreUpdated(uint256 indexed gameID, address indexed player, uint256 newScore);
    event JackpotConfigured(uint256 indexed gameID, uint256 duration, uint256 topPlayersCount, uint256 profitPercentage);
    event JackpotDistributed(uint256 indexed gameID, address indexed winner, uint256 amount, uint256 period);
    event JackpotRollover(uint256 indexed gameID, uint256 amount, uint256 period);
    event LeaderboardUpdated(uint256 indexed gameID, uint256 period, address indexed player, uint256 newScore);
    
    // Leaderboard functions
    function updatePlayerStats(uint256 gameID, address player, uint256 points) external;
    function setPlayerName(address player, string calldata name) external;
    
    // View functions
    function getGameLeaderboard(uint256 gameID) external view returns (
        address[] memory players,
        uint256[] memory earnings,
        string[] memory names,
        uint256[] memory scores
    );
    
    function getPlayerName(address player) external view returns (string memory);
    function getPlayerTotalScore(uint256 gameID, address player) external view returns (uint256);
    function getPlayerTotalEarnings(uint256 gameID, address player) external view returns (uint256);
    function getGamePlayerCount(uint256 gameID) external view returns (uint256);
    
    // Administrative functions
    function setOnchainGameManager(address _onchainGameManager) external;
    function setEarningsContract(address _earningsContract) external;
    
    // Jackpot management functions
    function configureJackpot(
        uint256 gameID,
        uint256 duration,
        uint256 topPlayersCount
    ) external;
    
    // Jackpot view functions
    function getJackpotConfig(uint256 gameID) external view returns (
        uint256 duration,
        uint256 topPlayersCount,
        uint256 startTime
    );
    
    function getCurrentJackpot(uint256 gameID) external view returns (uint256);
}
