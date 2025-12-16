// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Interface for OnchainGameManager
interface IOnchainGameManager {
    function getGameInfo(uint256 gameID) external view returns (
        string memory gameName,
        address gameTypeContract,
        address tokenAddress,
        uint256[] memory allowedBets,
        bool useNativeToken,
        address creator,
        string memory gameType
    );
    function isValidBet(uint256 gameID, uint256 betAmount) external view returns (bool);
    function earningsContract() external view returns (address);
    function leaderboardContract() external view returns (address);
}

// Interface for OnchainGameEarnings
interface IOnchainGameEarnings {
    function recordBetAndCheckBalance(uint256 gameID, address player, uint256 betAmount, uint256 maxWinMultiplier) external payable;
    function payEarnings(uint256 gameID, address player, uint256 amount, uint256 score) external;
    function updatePlayerStats(uint256 gameID, address player, uint256 points) external;
}

// Interface for OnchainGameLeaderboard
interface IOnchainGameLeaderboard {
    function updatePlayerStats(uint256 gameID, address player, uint256 points) external;
}

/**
 * @title MultiplierWithScoreGame
 * @dev A two-phase onchain game that combines random multipliers with score-based gameplay
 * @notice Phase 1: playGame() draws a random multiplier. Phase 2: endGame() applies score for final earnings
 */
contract MultiplierWithScoreGame is Ownable, ReentrancyGuard, Pausable {
    
    // Game constants - multiplier ranges (tuned for ~10% house edge at PERFECT score 10000)
    uint256 private constant LOW_MULTIPLIER_THRESHOLD = 7000;   // 70% chance for 0.8x multiplier
    uint256 private constant MID_MULTIPLIER_THRESHOLD = 9000;   // 20% chance for 1.2x multiplier  
    uint256 private constant HIGH_MULTIPLIER_THRESHOLD = 9800;  // 8% chance for 1.8x multiplier
    uint256 private constant MAX_MULTIPLIER_THRESHOLD = 10000;  // 2% chance for 3x multiplier
    
    uint256 private constant LOW_MULTIPLIER = 80;     // 0.8x (stored as 80 for precision)
    uint256 private constant MID_MULTIPLIER = 120;    // 1.2x
    uint256 private constant HIGH_MULTIPLIER = 180;   // 1.8x
    uint256 private constant MAX_MULTIPLIER = 300;    // 3x
    uint256 private constant MULTIPLIER_PRECISION = 100; // Divide by 100 to get actual multiplier
    
    // Contract configuration
    address public immutable factory;
    
    // Player game states
    struct PlayerGame {
        uint256 betAmount;
        uint256 multiplier;
        bool hasActiveGame;
        uint256 gameStartTime;
    }
    
    // Mapping: gameID => player => PlayerGame
    mapping(uint256 => mapping(address => PlayerGame)) public playerGames;
    
    // Events
    event GameStarted(address indexed player, uint256 indexed gameID, uint256 betAmount, uint256 multiplier);
    event GameEnded(address indexed player, uint256 indexed gameID, uint256 score, uint256 finalEarnings, uint256 points);
    
    // Custom errors
    error InvalidBetAmount(uint256 amount);
    error InsufficientBalance(uint256 required, uint256 available);
    error TransferFailed();
    error OnlyFactory();
    error GameNotFound(uint256 gameID);
    error NoActiveGame();
    error GameAlreadyActive();
    error InvalidScore(uint256 score);
    
    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }
    
    /**
     * @dev Constructor
     * @param _factory Address of the OnchainGameManager
     */
    constructor(address _factory) Ownable() {
        factory = _factory;
    }
    
    /**
     * @dev Start a new multiplier game - Phase 1
     * @param gameID ID of the game to play
     * @param betAmount Bet amount for the game
     * @return multiplier The random multiplier drawn for this game (scaled by MULTIPLIER_PRECISION)
     */
    function playGame(uint256 gameID, uint256 betAmount) 
        external payable nonReentrant whenNotPaused returns (uint256 multiplier) {
        
        // Check if player already has an active game
        if (playerGames[gameID][msg.sender].hasActiveGame) revert GameAlreadyActive();
        
        // Get game info from factory
        IOnchainGameManager manager = IOnchainGameManager(factory);

        (
            , // game name
            , // gameTypeContract
            , // rewardToken
            , // allowedBets
            , // useNativeToken
            , // creator
            string memory gameType
        ) = manager.getGameInfo(gameID);

        // Validate game exists
        if (bytes(gameType).length == 0) revert GameNotFound(gameID);

        // Get the earnings contract from manager
        IOnchainGameEarnings earnings = IOnchainGameEarnings(manager.earningsContract());
    
        // The earnings contract will check bet validity and handle payment
        // Use MAX_MULTIPLIER as the maximum possible win multiplier for balance checking
        earnings.recordBetAndCheckBalance{value: msg.value}(gameID, msg.sender, betAmount, MAX_MULTIPLIER / MULTIPLIER_PRECISION);

        // Generate random multiplier
        multiplier = _generateRandomMultiplier();
        
        // Store player game state
        playerGames[gameID][msg.sender] = PlayerGame({
            betAmount: betAmount,
            multiplier: multiplier,
            hasActiveGame: true,
            gameStartTime: block.timestamp
        });

        emit GameStarted(msg.sender, gameID, betAmount, multiplier);
        return multiplier;
    }
    
    /**
     * @dev End the game with a score - Phase 2
     * @param gameID ID of the game to end
     * @param score Player's gameplay score (should be between 0-10000 for best results)
     * @return finalEarnings The final earnings calculated as betAmount * multiplier * score / 10000
     */
    function endGame(uint256 gameID, uint256 score) 
        external nonReentrant whenNotPaused returns (uint256 finalEarnings) {
        
        // Check if player has an active game
        PlayerGame storage game = playerGames[gameID][msg.sender];
        if (!game.hasActiveGame) revert NoActiveGame();
        
        // Validate score (reasonable range to prevent overflow)
        if (score > 100) revert InvalidScore(score); // Max score of 100 for safety

        // Get game info from factory
        IOnchainGameManager manager = IOnchainGameManager(factory);
        IOnchainGameEarnings earnings = IOnchainGameEarnings(manager.earningsContract());
        
        // Calculate final earnings: betAmount * multiplier * score / (MULTIPLIER_PRECISION * 100)
        // This allows for fractional multipliers and score-based scaling (max score = 10000)

        finalEarnings = (game.betAmount * game.multiplier * score) / (MULTIPLIER_PRECISION * 100);
        
        // Calculate points: combination of bet amount, multiplier, and score
        uint256 points = finalEarnings / 1e15; // Example: 1 point per 0.001 token earned

        // Get the leaderboard contract from manager
        IOnchainGameLeaderboard leaderboard = IOnchainGameLeaderboard(manager.leaderboardContract());

        // Clear the game state first to prevent reentrancy
        game.hasActiveGame = false;
        
        // Handle rewards and leaderboard updates through earnings contract
        if (finalEarnings > 0) {
            // Pay earnings directly and update leaderboard with points as score
            earnings.payEarnings(gameID, msg.sender, finalEarnings, points);
        } else {
            // For zero earnings, still award some points based on participation
            uint256 participationPoints = game.betAmount / 1000; // Small participation reward
            earnings.updatePlayerStats(gameID, msg.sender, participationPoints > 0 ? participationPoints : 1);
        }

        emit GameEnded(msg.sender, gameID, score, finalEarnings, points);
        return finalEarnings;
    }
    
    /**
     * @dev Get player's current game state
     * @param gameID ID of the game
     * @param player Address of the player
     * @return betAmount The bet amount for the active game
     * @return multiplier The multiplier for the active game
     * @return hasActiveGame Whether the player has an active game
     * @return gameStartTime When the game was started
     */
    function getPlayerGame(uint256 gameID, address player) external view returns (
        uint256 betAmount,
        uint256 multiplier,
        bool hasActiveGame,
        uint256 gameStartTime
    ) {
        PlayerGame memory game = playerGames[gameID][player];
        return (game.betAmount, game.multiplier, game.hasActiveGame, game.gameStartTime);
    }
    
    /**
     * @dev Get game constants and multiplier ranges
     * @return lowThreshold Threshold for low multiplier (50%)
     * @return midThreshold Threshold for mid multiplier (30%) 
     * @return highThreshold Threshold for high multiplier (15%)
     * @return maxThreshold Threshold for max multiplier (5%)
     * @return lowMult Low multiplier value (1.5x)
     * @return midMult Mid multiplier value (2x)
     * @return highMult High multiplier value (3x)
     * @return maxMult Max multiplier value (5x)
     */
    function getGameConstants() external pure returns (
        uint256 lowThreshold,
        uint256 midThreshold,
        uint256 highThreshold,
        uint256 maxThreshold,
        uint256 lowMult,
        uint256 midMult,
        uint256 highMult,
        uint256 maxMult
    ) {
        return (
            LOW_MULTIPLIER_THRESHOLD,
            MID_MULTIPLIER_THRESHOLD,
            HIGH_MULTIPLIER_THRESHOLD,
            MAX_MULTIPLIER_THRESHOLD,
            LOW_MULTIPLIER,
            MID_MULTIPLIER,
            HIGH_MULTIPLIER,
            MAX_MULTIPLIER
        );
    }
    
    /**
     * @dev Generates a random multiplier based on probability thresholds
     * @return multiplier Random multiplier (scaled by MULTIPLIER_PRECISION)
     */
    function _generateRandomMultiplier() private view returns (uint256 multiplier) {
        uint256 randomValue = _generateSecureRandom();
        
        if (randomValue < LOW_MULTIPLIER_THRESHOLD) {
            return LOW_MULTIPLIER;   // 50% chance for 1.5x
        } else if (randomValue < MID_MULTIPLIER_THRESHOLD) {
            return MID_MULTIPLIER;   // 30% chance for 2x
        } else if (randomValue < HIGH_MULTIPLIER_THRESHOLD) {
            return HIGH_MULTIPLIER;  // 15% chance for 3x
        } else {
            return MAX_MULTIPLIER;   // 5% chance for 5x
        }
    }
    
    /**
     * @dev Generates a secure pseudo-random number using multiple entropy sources
     * @return A pseudo-random number between 0 and 9999
     */
    function _generateSecureRandom() private view returns (uint256) {
        uint256 entropy = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            address(this),
            block.number,
            gasleft()
        )));
        
        return entropy % 10000;
    }
    
    /**
     * @dev Pause the contract (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the contract (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Receive function to accept native token payments
     */
    receive() external payable {}
}
