// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IOnchainGameLeaderboard.sol";
import "./IOnchainGameManager.sol";
import "./IOnchainGameEarnings.sol";

/**
 * @title OnchainGameLeaderboard
 * @dev Handles leaderboards, player statistics, and jackpot management
 * @notice This contract manages player statistics, leaderboard data, and jackpot distribution
 */
contract OnchainGameLeaderboard is IOnchainGameLeaderboard, Ownable, ReentrancyGuard {
    
    // Contract references
    address public onchainGameManager;
    address public earningsContract;
    

    // Jackpot structures
    struct JackpotConfig {
        uint256 duration;           // Duration in seconds (1 day = 86400, 7 days = 604800)
        uint256 topPlayersCount;    // Number of top players eligible for jackpot drawing pool
        uint256 currentPeriodStart; // When current period started
        uint256 currentPeriodEnd;   // When current period ends
        uint256 currentPeriodNumber; // Sequential period counter
    }
    
    // Current period leaderboard (simplified - only one period at a time)
    struct CurrentPeriodData {
        PlayerScore[] leaderboard;
        mapping(address => PlayerPeriodScore) playerScores;
        uint256 periodNumber;       // For tracking/display purposes
    }
    
    // Player score with period tracking
    struct PlayerPeriodScore {
        uint256 score;
        uint256 periodNumber;
    }
    
    // Player data
    mapping(address => string) public playerNames;
    
    // Game-specific player data
    mapping(uint256 => address[]) public gamePlayers;
    mapping(uint256 => mapping(address => uint256)) public playerGameScores;
    mapping(uint256 => mapping(address => bool)) public hasPlayedGame;
    
    // Jackpot data
    mapping(uint256 => JackpotConfig) public jackpotConfigs; // Updated name for consistency
    mapping(uint256 => CurrentPeriodData) public currentPeriodData; // Updated name for consistency
    
    // Custom errors
    error GameNotFound(uint256 gameID);
    error ZeroAddress();
    error Unauthorized();
    error JackpotNotEnabled(uint256 gameID);
    error InvalidPercentage();
    error InvalidDuration();
    error NoWinnersFound();
    error JackpotAlreadyTriggered(uint256 gameID);
    error JackpotPeriodNotComplete(uint256 gameID, uint256 timeRemaining);
    error InsufficientJackpotFunds(uint256 gameID);

    // Events
    event JackpotTriggered(uint256 indexed gameID,uint256 indexed periodNumber, address indexed triggerBy);
    event JackpotNoWinner(uint256 indexed gameID, uint256 indexed periodNumber);
    event PeriodReset(uint256 indexed gameID, uint256 oldPeriod, uint256 newPeriod, uint256 newStartTime, uint256 newEndTime);
    event JackpotWon(uint256 indexed gameID, address indexed winner, uint256 amount, uint256 indexed periodNumber, uint256 timestamp);

    /**
     * @dev Constructor sets the initial owner
     */
    constructor() Ownable() {
        // Contract is ready to manage leaderboards
    }
    
    // Modifiers
    modifier onlyGameManagerOrOwner() {
        if (msg.sender != onchainGameManager && msg.sender != owner()) revert Unauthorized();
        _;
    }
    
    modifier onlyGameCreatorOrManagerOrOwner(uint256 gameID) {
        bool isGameCreator = false;
        
        // Check if caller is the game creator
        if (onchainGameManager != address(0)) {
            try IOnchainGameManager(onchainGameManager).getGameCreator(gameID) returns (address creator) {
                isGameCreator = (msg.sender == creator);
            } catch {
                // If getGameCreator fails, assume false
                isGameCreator = false;
            }
        }
        
        if (msg.sender != onchainGameManager && msg.sender != owner() && !isGameCreator) {
            revert Unauthorized();
        }
        _;
    }
    
    /**
     * @dev Set the onchain game manager contract (only owner)
     * @param _onchainGameManager Address of the onchain game manager contract
     */
    function setOnchainGameManager(address _onchainGameManager) external override onlyOwner {
        if (_onchainGameManager == address(0)) revert ZeroAddress();
        onchainGameManager = _onchainGameManager;
    }
    
    /**
     * @dev Set the earnings contract (only owner)
     * @param _earningsContract Address of the earnings contract
     */
    function setEarningsContract(address _earningsContract) external override onlyOwner {
        earningsContract = _earningsContract;
    }
    
    /**
     * @dev Update player statistics (called by earnings contract)
     * @param gameID Name of the game
     * @param player Player address
     * @param points Points to add to totalScore
     */
    function updatePlayerStats(uint256 gameID, address player, uint256 points) 
        external 
        override
    {
        // Only earnings contract can call this
        if (msg.sender != earningsContract) revert Unauthorized();
        
        // Verify game exists
        if (onchainGameManager == address(0) || !IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }

        // Add player to game players list if first time
        if (!hasPlayedGame[gameID][player]) {
            gamePlayers[gameID].push(player);
            hasPlayedGame[gameID][player] = true;
        }

        // Update player's total score for this game
        playerGameScores[gameID][player] += points;

        // Update current period leaderboard if jackpot is configured for this game
        JackpotConfig storage config = jackpotConfigs[gameID];
        if (config.duration > 0) {
            _updateCurrentPeriodLeaderboard(gameID, player, points);
        }

        emit ScoreUpdated(gameID, player, playerGameScores[gameID][player]);
    }
    
    /**
     * @dev Set player name
     * @param player Player address
     * @param name Player name
     */
    function setPlayerName(address player, string calldata name) external override {
        // Can be called by the player themselves or the earnings contract
        if (msg.sender != player && msg.sender != earningsContract) revert Unauthorized();
        
        playerNames[player] = name;
        emit PlayerNameSet(player, name);
    }
    
    /**
     * @dev Get leaderboard data for a game (unsorted)
     * @param gameID Name of the game
     * @return players Array of player addresses
     * @return earnings Array of corresponding total earnings
     * @return names Array of corresponding player names
     * @return scores Array of corresponding total scores
     */
    function getGameLeaderboard(uint256 gameID) external view override returns (
        address[] memory players,
        uint256[] memory earnings,
        string[] memory names,
        uint256[] memory scores
    ) {
        // Verify game exists
        if (onchainGameManager == address(0) || !IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }

        address[] memory allPlayers = gamePlayers[gameID];
        uint256 playerCount = allPlayers.length;

        if (playerCount == 0) {
            return (new address[](0), new uint256[](0), new string[](0), new uint256[](0));
        }

        // Create arrays with earnings, names, and scores data
        players = new address[](playerCount);
        earnings = new uint256[](playerCount);
        names = new string[](playerCount);
        scores = new uint256[](playerCount);

        for (uint256 i = 0; i < playerCount; i++) {
            address p = allPlayers[i];
            players[i] = p;
            
            // Get earnings from earnings contract
            if (earningsContract != address(0)) {
                earnings[i] = IOnchainGameEarnings(earningsContract).getTotalEarnings(gameID, p);
            } else {
                earnings[i] = 0;
            }
            
            names[i] = playerNames[p];
            scores[i] = playerGameScores[gameID][p];
        }

        return (players, earnings, names, scores);
    }
    
    /**
     * @dev Get player name
     * @param player Player address
     * @return Player name
     */
    function getPlayerName(address player) external view override returns (string memory) {
        return playerNames[player];
    }
    
    /**
     * @dev Get player's total score for a specific game
     * @param gameID Name of the game
     * @param player Player address
     * @return Total score for the player in the game
     */
    function getPlayerTotalScore(uint256 gameID, address player) external view override returns (uint256) {
        return playerGameScores[gameID][player];
    }
    
    /**
     * @dev Get player's total earnings for a specific game
     * @param gameID Name of the game
     * @param player Player address
     * @return Total earnings for the player in the game
     */
    function getPlayerTotalEarnings(uint256 gameID, address player) external view override returns (uint256) {
        if (earningsContract == address(0)) return 0;
        return IOnchainGameEarnings(earningsContract).getTotalEarnings(gameID, player);
    }
    
    /**
     * @dev Get the number of players who have played a specific game
     * @param gameID Name of the game
     * @return Number of players
     */
    function getGamePlayerCount(uint256 gameID) external view override returns (uint256) {
        return gamePlayers[gameID].length;
    }
    
    /**
     * @dev Check if a player has played a specific game
     * @param gameID Name of the game
     * @param player Player address
     * @return True if the player has played the game
     */
    function hasPlayerPlayedGame(uint256 gameID, address player) external view returns (bool) {
        return hasPlayedGame[gameID][player];
    }
    
    /**
     * @dev Get all players for a specific game
     * @param gameID Name of the game
     * @return Array of player addresses
     */
    function getGamePlayers(uint256 gameID) external view returns (address[] memory) {
        return gamePlayers[gameID];
    }
    
    // JACKPOT MANAGEMENT FUNCTIONS
    
    /**
     * @dev Configure jackpot settings for a game with simplified period management
     * @param gameID Name of the game
     * @param periodDurationHours Duration of each jackpot period in hours
     * @param topPlayersCount Number of top players eligible for jackpot drawing pool
     */
    function configureJackpot(
        uint256 gameID,
        uint256 periodDurationHours,
        uint256 topPlayersCount
    ) external onlyGameCreatorOrManagerOrOwner(gameID) {
        
        if (periodDurationHours == 0) revert InvalidDuration();
        if (topPlayersCount == 0 || topPlayersCount > 50) revert InvalidDuration(); // Hard limit of 50 players
        
        JackpotConfig storage config = jackpotConfigs[gameID];
        config.duration = periodDurationHours /* * 1 hours */;
        config.topPlayersCount = topPlayersCount;
        
        
        // Initialize current period if this is first time setup
        if (config.currentPeriodStart == 0) {
            config.currentPeriodStart = block.timestamp;
            config.currentPeriodEnd = block.timestamp + config.duration;
            config.currentPeriodNumber = 1;
            
            // Initialize the current period data to match the config
            CurrentPeriodData storage currentData = currentPeriodData[gameID];
            currentData.periodNumber = config.currentPeriodNumber;
        }
    }

    /**
     * @dev Get current period information for a game
     */
    function getCurrentPeriodInfo(uint256 gameID) external view returns (
        uint256 periodNumber,
        uint256 startTime,
        uint256 endTime,
        bool periodComplete
    ) {
        JackpotConfig storage config = jackpotConfigs[gameID];
        return (
            config.currentPeriodNumber,
            config.currentPeriodStart,
            config.currentPeriodEnd,
            block.timestamp >= config.currentPeriodEnd
        );
    }

    /**
     * @dev Check if current period data is valid (for debugging)
     * @param gameID Name of the game
     * @return isValid True if period data is current and valid
     * @return configPeriod Current period number from config
     * @return dataPeriod Period number stored in current period data
     */
    function isPeriodDataValid(uint256 gameID) external view returns (
        bool isValid,
        uint256 configPeriod,
        uint256 dataPeriod
    ) {
        JackpotConfig storage config = jackpotConfigs[gameID];
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        
        configPeriod = config.currentPeriodNumber;
        dataPeriod = currentData.periodNumber;
        isValid = (configPeriod == dataPeriod);
        
        return (isValid, configPeriod, dataPeriod);
    }

    /**
     * @dev Check if jackpot can be triggered for a game
     */
    function canTriggerJackpot(uint256 gameID) external view returns (bool) {
        JackpotConfig storage config = jackpotConfigs[gameID];
        
        //Jackpot not enabled
        if (config.duration == 0) {
            return false;
        }
        
        if (block.timestamp < config.currentPeriodEnd) {
            return false;
        }
        
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        if (currentData.leaderboard.length == 0) {
            return false;
        }
        
        return true;
    }

    /**
     * @dev Internal function to update current period leaderboard (optimized insertion)
     */
    function _updateCurrentPeriodLeaderboard(uint256 gameID, address player, uint256 points) internal {
        JackpotConfig storage config = jackpotConfigs[gameID];
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        
        // Get current player score with period validation
        PlayerPeriodScore storage playerPeriodScore = currentData.playerScores[player];
        uint256 currentPlayerScore = 0;
        
        // Only use existing score if it's from the current period
        if (playerPeriodScore.periodNumber == config.currentPeriodNumber) {
            currentPlayerScore = playerPeriodScore.score;
        }
        
        // Update player's period score with new period number
        uint256 newScore = currentPlayerScore + points;
        currentData.playerScores[player] = PlayerPeriodScore({
            score: newScore,
            periodNumber: config.currentPeriodNumber
        });
        
        // Check if player is already in leaderboard and remove them
        uint256 currentIndex = type(uint256).max; // Use max value to indicate "not found"
        for (uint256 i = 0; i < currentData.leaderboard.length; i++) {
            if (currentData.leaderboard[i].player == player) {
                currentIndex = i;
                // Remove player by shifting all elements left
                for (uint256 j = i; j < currentData.leaderboard.length - 1; j++) {
                    currentData.leaderboard[j] = currentData.leaderboard[j + 1];
                }
                currentData.leaderboard.pop();
                break;
            }
        }
        
        // Find insertion position (start from the end - lowest scores)
        uint256 insertPosition = currentData.leaderboard.length;
        for (uint256 i = currentData.leaderboard.length; i > 0; i--) {
            if (newScore > currentData.leaderboard[i - 1].score) {
                insertPosition = i - 1;
            } else {
                break;
            }
        }
        
        // Insert player at the correct position if within the limit
        if (insertPosition < config.topPlayersCount) {
            // Add space at the end for shifting (if at capacity, last player will be naturally dropped)
            currentData.leaderboard.push(PlayerScore({player: address(0), score: 0}));
            
            // Shift elements down to make room at insertPosition
            for (uint256 i = currentData.leaderboard.length - 1; i > insertPosition; i--) {
                currentData.leaderboard[i] = currentData.leaderboard[i - 1];
            }
            
            // Insert the player at the correct position
            currentData.leaderboard[insertPosition] = PlayerScore({player: player, score: newScore});
            
            // If we exceeded the limit, remove the last element (lowest scorer gets dropped)
            if (currentData.leaderboard.length > config.topPlayersCount) {
                currentData.leaderboard.pop();
            }
        }
    }

    /**
     * @dev Manually trigger jackpot with 50% probability (anyone can call)
     * @param gameID Name of the game
     */
    function triggerJackpot(uint256 gameID) external nonReentrant {
        JackpotConfig storage config = jackpotConfigs[gameID];
        
        // Check if period is complete
        if (block.timestamp < config.currentPeriodEnd) {
            uint256 timeRemaining = config.currentPeriodEnd - block.timestamp;
            revert JackpotPeriodNotComplete(gameID, timeRemaining);
        }
        
        // Check if there are players in current period
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        if (currentData.leaderboard.length == 0) revert NoWinnersFound();
        
        // 50% probability check using pseudo-random number
        // Using block properties and transaction data for randomness
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            block.number,
            msg.sender,
            gameID,
            currentData.leaderboard.length
        )));
        
        bool jackpotWin = (randomSeed % 2) == 0; // 50% probability
        
        if (jackpotWin) {
            // Trigger successful jackpot
            _executeJackpot(gameID);
            emit JackpotTriggered(gameID, config.currentPeriodNumber, msg.sender);
        } else {
            // No jackpot winner, but still mark as triggered and reset period
            emit JackpotNoWinner(gameID, config.currentPeriodNumber);
            
            // Reset to next period
            _resetToNextPeriod(gameID);
        }
    }

    /**
     * @dev Internal function to execute jackpot distribution
     */
    function _executeJackpot(uint256 gameID) internal {
        JackpotConfig storage config = jackpotConfigs[gameID];
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        
        // Determine eligible players pool (limited by topPlayersCount)
        uint256 eligiblePlayersCount = currentData.leaderboard.length < config.topPlayersCount ? 
                                     currentData.leaderboard.length : config.topPlayersCount;
        
        if (eligiblePlayersCount == 0) revert InsufficientJackpotFunds(gameID);
        
        // Calculate total score for weighted random selection
        uint256 totalScore = 0;
        for (uint256 i = 0; i < eligiblePlayersCount; i++) {
            totalScore += currentData.leaderboard[i].score;
        }
        
        if (totalScore == 0) revert InsufficientJackpotFunds(gameID); // No scores to weight by
        
        // Generate random number weighted by scores
        uint256 randomValue = uint256(keccak256(abi.encodePacked(
            block.timestamp, 
            block.prevrandao, 
            gameID,
            currentData.leaderboard.length
        ))) % totalScore;
        
        // Select winner based on weighted probability
        address jackpotWinner;
        uint256 cumulativeScore = 0;
        for (uint256 i = 0; i < eligiblePlayersCount; i++) {
            cumulativeScore += currentData.leaderboard[i].score;
            if (randomValue < cumulativeScore) {
                jackpotWinner = currentData.leaderboard[i].player;
                break;
            }
        }
        
        // Pay jackpot through earnings contract (calculates amount based on profits)
        uint256 jackpotAmount = IOnchainGameEarnings(earningsContract).payJackpot(gameID, jackpotWinner);
        
        // Only emit event if jackpot was actually paid
        if (jackpotAmount > 0) {
            emit JackpotWon(gameID, jackpotWinner, jackpotAmount, config.currentPeriodNumber, block.timestamp);
        } else {
            // No jackpot paid (insufficient funds or profits)
            emit JackpotNoWinner(gameID, config.currentPeriodNumber);
        }
        
        // Reset to next period
        _resetToNextPeriod(gameID);
    }

    /**
     * @dev Internal function to reset to next period
     */
    function _resetToNextPeriod(uint256 gameID) internal {
        JackpotConfig storage config = jackpotConfigs[gameID];
        uint256 oldPeriod = config.currentPeriodNumber;
        
        // Set next period
        config.currentPeriodNumber += 1;
        config.currentPeriodStart = config.currentPeriodEnd;
        config.currentPeriodEnd = config.currentPeriodStart + (config.duration);
        
        // Clear current period data and initialize for new period
        delete currentPeriodData[gameID];
        
        // Initialize the new period data
        CurrentPeriodData storage newPeriodData = currentPeriodData[gameID];
        newPeriodData.periodNumber = config.currentPeriodNumber;
        
        emit PeriodReset(gameID, oldPeriod, config.currentPeriodNumber, 
                        config.currentPeriodStart, config.currentPeriodEnd);
    }
    
    
    /**
     * @dev Get jackpot configuration for a game
     * @param gameID Name of the game
     * @return duration Period duration in seconds
     * @return topPlayersCount Number of top players eligible for jackpot
     * @return startTime Current period start time
     */
    function getJackpotConfig(uint256 gameID) external view returns (
        uint256 duration,
        uint256 topPlayersCount,
        uint256 startTime
    ) {
        JackpotConfig storage config = jackpotConfigs[gameID];
        
        return (
            config.duration,
            config.topPlayersCount,
            config.currentPeriodStart
        );
    }
    
    /**
     * @dev Get current period leaderboard for a game
     * @param gameID Name of the game
     * @return Array of player scores for the current period
     */
    function getCurrentPeriodLeaderboard(uint256 gameID) external view returns (PlayerScore[] memory) {
        return currentPeriodData[gameID].leaderboard;
    }
    
    /**
     * @dev Get player's score for current period
     * @param gameID Name of the game
     * @param player Player address
     * @return Player's score for current period
     */
    function getCurrentPeriodPlayerScore(uint256 gameID, address player) external view returns (uint256) {
        JackpotConfig storage config = jackpotConfigs[gameID];
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        
        PlayerPeriodScore storage playerPeriodScore = currentData.playerScores[player];
        
        // Only return score if it's from the current period
        if (playerPeriodScore.periodNumber == config.currentPeriodNumber) {
            return playerPeriodScore.score;
        }
        
        return 0; // Score is from old period or player hasn't played this period
    }
    
    /**
     * @dev Get all players who participated in current period with their scores
     * @param gameID Name of the game
     * @return players Array of player addresses who participated in current period
     * @return scores Array of corresponding scores for current period
     * @return names Array of corresponding player names
     */
    function getCurrentPeriodAllPlayers(uint256 gameID) external view returns (
        address[] memory players,
        uint256[] memory scores,
        string[] memory names
    ) {
        JackpotConfig storage config = jackpotConfigs[gameID];
        CurrentPeriodData storage currentData = currentPeriodData[gameID];
        
        // If periods don't match, return empty arrays (old data is invalid)
        if (currentData.periodNumber != config.currentPeriodNumber) {
            return (new address[](0), new uint256[](0), new string[](0));
        }
        
        // Get all players who have ever played the game
        address[] memory allGamePlayers = gamePlayers[gameID];
        
        // Count players with scores > 0 in current period
        uint256 activePlayersCount = 0;
        for (uint256 i = 0; i < allGamePlayers.length; i++) {
            PlayerPeriodScore storage playerPeriodScore = currentData.playerScores[allGamePlayers[i]];
            // Only count if score is from current period and > 0
            if (playerPeriodScore.periodNumber == config.currentPeriodNumber && playerPeriodScore.score > 0) {
                activePlayersCount++;
            }
        }
        
        // Create arrays for active players
        players = new address[](activePlayersCount);
        scores = new uint256[](activePlayersCount);
        names = new string[](activePlayersCount);

        // Populate arrays with active players
        uint256 index = 0;
        for (uint256 i = 0; i < allGamePlayers.length; i++) {
            address player = allGamePlayers[i];
            PlayerPeriodScore storage playerPeriodScore = currentData.playerScores[player];
            
            // Only include if score is from current period and > 0
            if (playerPeriodScore.periodNumber == config.currentPeriodNumber && playerPeriodScore.score > 0) {
                players[index] = player;
                scores[index] = playerPeriodScore.score;
                names[index] = playerNames[player];
                index++;
            }
        }

        return (players, scores, names);
    }
    
    /**
     * @dev Get current jackpot amount for a game
     * @param gameID Name of the game
     * @return Current jackpot amount (actual payout amount - 90% of accumulated)
     */
    function getCurrentJackpot(uint256 gameID) external view override returns (uint256) {
        if (earningsContract == address(0)) return 0;
        
        // Get actual jackpot payout amount (90% of accumulated jackpot funds)
        return IOnchainGameEarnings(earningsContract).getJackpotPayoutAmount(gameID);
    }
}
        
