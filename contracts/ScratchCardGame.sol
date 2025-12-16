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
 * @title ScratchCardGame
 * @dev A simple scratch card onchain game with only playGame function
 * @notice This contract handles scratch card game logic and integrates with OnchainGameManager
 */
contract ScratchCardGame is Ownable, ReentrancyGuard, Pausable {
    
    // Game constants - hardcoded probabilities and multipliers
    uint256 private constant LOSE_THRESHOLD = 7500; // 75% chance to lose (0-7499)
    uint256 private constant WIN_THRESHOLD = 9500;  // 20% chance to win (7500-9499)
    uint256 private constant SUPERWIN_THRESHOLD = 10000; // 5% chance to superwin (9500-9999)
    
    uint256 private constant WIN_MULTIPLIER = 2;     // 2x reward for win
    uint256 private constant SUPERWIN_MULTIPLIER = 5; // 5x reward for superwin
    
    // Contract configuration
    address public immutable factory;
    
    // Game statistics
    uint256 public totalGamesPlayed;
    uint256 public totalBetsCollected;
    uint256 public totalWinningsPaid;
    
    // Pending earnings tracking (game contract manages its own pending state)
    mapping(uint256 => mapping(address => uint256)) public pendingEarnings;
    
    // Events
    event EarningsClaimed(address indexed player, uint256 indexed gameID, uint256 amount);
    event GamePlayed(address indexed player, uint256 indexed gameID, uint256 betAmount, uint8 result, uint256 winnings, uint256 points);
    
    // Custom errors
    error InvalidBetAmount(uint256 amount);
    error InsufficientBalance(uint256 required, uint256 available);
    error TransferFailed();
    error OnlyFactory();
    error GameNotFound(uint256 gameID);
    error NoEarningsToClaim(uint256 gameID);
    
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
     * @dev Play a scratch card game
     * @param gameID Name of the game to play
     * @param initialBet Bet amount for the scratch card
     * @return result Game result (0=lose, 1=win, 2=superwin)
     * @return reward Amount won (if any)
     */
    function playGame(uint256 gameID, uint256 initialBet) 
        external payable nonReentrant whenNotPaused returns (uint8 result, uint256 reward) {
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
        earnings.recordBetAndCheckBalance{value: msg.value}(gameID, msg.sender, initialBet, SUPERWIN_MULTIPLIER);

        // Generate secure random number for game outcome
        uint256 randomValue = _generateSecureRandom();

        // Determine outcome based on probabilities
        if (randomValue < LOSE_THRESHOLD) {
            result = 0; // Lose
            reward = 0;
        } else if (randomValue < WIN_THRESHOLD) {
            result = 1; // Win
            reward = initialBet * WIN_MULTIPLIER;
        } else {
            result = 2; // Superwin
            reward = initialBet * SUPERWIN_MULTIPLIER;
        }

        // Update statistics
        totalGamesPlayed++;
        totalBetsCollected += initialBet;

        // Calculate points: bet amount + earnings - balanced jackpot system
        // This rewards both participation (bet) and success (winnings)
        uint256 points = initialBet + reward;
        
        // Handle rewards and leaderboard updates
        if (reward > 0) {
            // Store pending earnings locally in this contract
            pendingEarnings[gameID][msg.sender] += reward;
            totalWinningsPaid += reward;
            
            // Update leaderboard stats directly
            earnings.updatePlayerStats(gameID, msg.sender, points);
        } else {
            // For losses, still award points based on bet amount for participation
            earnings.updatePlayerStats(gameID, msg.sender, points);
        }

        emit GamePlayed(msg.sender, gameID, initialBet, result, reward, points);
        return (result, reward);
    }
    
    /**
     * @dev Claim pending earnings from a scratch card game
     * @param gameID ID of the game to claim earnings from
     * @return amount Amount claimed
     */
    function claimEarnings(uint256 gameID) 
        external nonReentrant whenNotPaused returns (uint256 amount) {
        
        amount = pendingEarnings[gameID][msg.sender];
        if (amount == 0) {
            return 0; // No earnings to claim
        }
        
        // Clear pending earnings first to prevent reentrancy
        pendingEarnings[gameID][msg.sender] = 0;
        
        // Get the earnings contract from manager
        IOnchainGameManager manager = IOnchainGameManager(factory);
        IOnchainGameEarnings earnings = IOnchainGameEarnings(manager.earningsContract());
        
        // Calculate points for leaderboard (same as during game play)
        uint256 points = amount; // Simple points based on earnings amount
        
        // Call payEarnings to transfer funds directly to player
        earnings.payEarnings(gameID, msg.sender, amount, points);
        
        emit EarningsClaimed(msg.sender, gameID, amount);
        return amount;
    }
    
    /**
     * @dev Get pending earnings for a player in a specific game
     * @param gameID ID of the game
     * @param player Address of the player
     * @return Pending earnings amount
     */
    function getPendingEarnings(uint256 gameID, address player) external view returns (uint256) {
        return pendingEarnings[gameID][player];
    }
    
    /**
     * @dev Get game statistics
     * @return totalGames Total games played
     * @return totalBets Total bets collected
     * @return totalWinnings Total winnings paid
     */
    function getGameStats() external view returns (
        uint256 totalGames,
        uint256 totalBets,
        uint256 totalWinnings
    ) {
        return (totalGamesPlayed, totalBetsCollected, totalWinningsPaid);
    }
    
    /**
     * @dev Get game constants
     * @return loseThreshold The threshold for losing
     * @return winThreshold The threshold for winning
     * @return superwinThreshold The threshold for super winning
     * @return winMultiplier The multiplier for regular wins
     * @return superwinMultiplier The multiplier for super wins
     */
    function getGameConstants() external pure returns (
        uint256 loseThreshold,
        uint256 winThreshold, 
        uint256 superwinThreshold,
        uint256 winMultiplier,
        uint256 superwinMultiplier
    ) {
        return (
            LOSE_THRESHOLD,
            WIN_THRESHOLD,
            SUPERWIN_THRESHOLD,
            WIN_MULTIPLIER,
            SUPERWIN_MULTIPLIER
        );
    }
    
    /**
     * @dev Generates a secure pseudo-random number using multiple entropy sources
     * @return A pseudo-random number between 0 and 9999
     */
    function _generateSecureRandom() private view returns (uint256) {
        // Simplified but effective random number generation for lower gas cost
        uint256 entropy = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            address(this),
            totalGamesPlayed,
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

