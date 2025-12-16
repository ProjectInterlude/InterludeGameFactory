// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IOnchainGameEarnings.sol";
import "./IOnchainGameManager.sol";
import "./IOnchainGameLeaderboard.sol";

/**
 * @title OnchainGameEarnings
 * @dev Handles all earnings, fund management, and onchain operations
 * @notice This contract manages player earnings, game balances, and fund transfers
 */
contract OnchainGameEarnings is IOnchainGameEarnings, Ownable, ReentrancyGuard {
    
    // Fee structure - configurable percentages
    uint256 public ownerFeePercentage = 10;
    uint256 public jackpotContributionPercentage = 5; // 5% of each bet goes to jackpot
    uint256 public constant JACKPOT_PAYOUT_PERCENTAGE = 90; // Pay out 90% of jackpot, keep 10% for next round
    
    // Contract references
    address public onchainGameManager;
    address public leaderboardContract;
    address public feeReceiver; // Separate address for receiving owner fees
    
    // Clear fund separation
    mapping(uint256 => uint256) public houseFunds;           // House funds + game funding
    mapping(uint256 => uint256) public jackpotFunds;        // Accumulated jackpot funds
    mapping(uint256 => uint256) public ownerFeesEscrow;     // Owner fees waiting withdrawal
    
    // Player tracking
    mapping(uint256 => mapping(address => uint256)) public totalEarnings;
    
    // Game statistics
    mapping(uint256 => uint256) public gameTotalBets;
    mapping(uint256 => uint256) public gameTotalRewards;
    mapping(uint256 => uint256) public gameTotalFunded;
    mapping(uint256 => uint256) public gameTotalClaimed;
    
    // Custom errors
    error GameNotFound(uint256 gameID);
    error TransferFailed();
    error ZeroAddress();
    error Unauthorized();
    error InsufficientFunds(uint256 gameID, string fundType, uint256 required, uint256 available);
    error InvalidTokenConfiguration();
    error NoFeesToWithdraw();
    error ArrayLengthMismatch();
    error InsufficientJackpotFunds();

    // Events
    event FeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event OwnerFeesWithdrawn(address indexed receiver, uint256 amount);
    event OwnerFeePercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event JackpotContributionPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);
    event FundsDistributed(uint256 indexed gameID, uint256 houseAmount, uint256 ownerAmount, uint256 jackpotAmount);
    event JackpotPaid(uint256 indexed gameID, address indexed winner, uint256 amount);
    event GameFunded(uint256 indexed gameID, address indexed funder, uint256 amount);
    event GameFundsWithdrawn(uint256 indexed gameID, address indexed withdrawer, address indexed to, uint256 amount);
    event EarningsAdded(uint256 indexed gameID, address indexed player, uint256 amount);
    event EarningsClaimed(uint256 indexed gameID, address indexed player, uint256 amount);
    event JackpotFunded(uint256 indexed gameID, address indexed funder, uint256 amount);

    /**
     * @dev Constructor sets the initial owner and fee receiver
     */
    constructor() Ownable() {
        feeReceiver = msg.sender; // Default fee receiver to owner
    }
    
    /**
     * @dev Set the fee receiver address (only owner)
     * @param _feeReceiver Address to receive owner fees
     */
    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        if (_feeReceiver == address(0)) revert ZeroAddress();
        address oldReceiver = feeReceiver;
        feeReceiver = _feeReceiver;
        emit FeeReceiverUpdated(oldReceiver, _feeReceiver);
    }
    
    /**
     * @dev Set the owner fee percentage (only owner)
     * @param _percentage New owner fee percentage (0-100)
     */
    function setOwnerFeePercentage(uint256 _percentage) external onlyOwner {
        require(_percentage <= 100, "Percentage cannot exceed 100");
        uint256 oldPercentage = ownerFeePercentage;
        ownerFeePercentage = _percentage;
        emit OwnerFeePercentageUpdated(oldPercentage, _percentage);
    }
    
    /**
     * @dev Set the jackpot contribution percentage (only owner)
     * @param _percentage New jackpot contribution percentage (0-100)
     */
    function setJackpotContributionPercentage(uint256 _percentage) external onlyOwner {
        require(_percentage <= 100, "Percentage cannot exceed 100");
        uint256 oldPercentage = jackpotContributionPercentage;
        jackpotContributionPercentage = _percentage;
        emit JackpotContributionPercentageUpdated(oldPercentage, _percentage);
    }
    
    /**
     * @dev Set the onchain game manager contract (only owner)
     * @param _onchainGameManager Address of the onchain game manager contract
     */
    function setOnchainGameManager(address _onchainGameManager) external onlyOwner {
        if (_onchainGameManager == address(0)) revert ZeroAddress();
        onchainGameManager = _onchainGameManager;
    }
    
    /**
     * @dev Set the leaderboard contract (only owner)
     * @param _leaderboardContract Address of the leaderboard contract
     */
    function setLeaderboardContract(address _leaderboardContract) external onlyOwner {
        leaderboardContract = _leaderboardContract;
    }



    /**
     * @dev Update player stats without earnings (called by game contracts for losses)
     * @param gameID Name of the game
     * @param player Player
     * @param points Points to add to leaderboard
     */
    function updatePlayerStats(uint256 gameID, address player, uint256 points) 
        external 
        override
    {
        // Verify the game exists and caller is authorized
        _verifyGameAndAuthorization(gameID);

        // Update leaderboard stats if leaderboard contract is set
        if (leaderboardContract != address(0)) {
            IOnchainGameLeaderboard(leaderboardContract).updatePlayerStats(gameID, player, points);
        }
    }

    /**
     * @dev Pay earnings directly to player (called by game contracts after claim)
     * @param gameID ID of the game
     * @param player Player address to pay
     * @param amount Amount to pay
     * @param score Player's score for leaderboard
     * @notice This function can only be called by registered game contracts
     * @notice Game contracts must validate they have sufficient house balance before calling
     */
    function payEarnings(uint256 gameID, address player, uint256 amount, uint256 score) 
        external 
        nonReentrant
    {
        // Verify the game exists and caller is authorized
        _verifyGameAndAuthorization(gameID);

        // Validate amount is reasonable (game contracts should validate this too)
        if (amount > 0) {
            // Check if house has sufficient funds to pay the winnings
            if (houseFunds[gameID] < amount) {
                revert InsufficientFunds(gameID, "house", amount, houseFunds[gameID]);
            }
            
            // Move from house funds directly to the player (no pending state)
            houseFunds[gameID] -= amount;
            totalEarnings[gameID][player] += amount;
            gameTotalRewards[gameID] += amount;
            gameTotalClaimed[gameID] += amount;
            
            // Get game info to determine token type
            (,, address tokenAddress, , bool useNativeToken, , ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);
            
            // Transfer earnings directly to player
            if (useNativeToken) {
                // Transfer native tokens (ETH)
                (bool success, ) = payable(player).call{value: amount}("");
                if (!success) {
                    // Restore funds if transfer fails
                    houseFunds[gameID] += amount;
                    totalEarnings[gameID][player] -= amount;
                    gameTotalRewards[gameID] -= amount;
                    gameTotalClaimed[gameID] -= amount;
                    revert TransferFailed();
                }
            } else {
                // Transfer ERC-20 tokens
                if (!IERC20(tokenAddress).transfer(player, amount)) {
                    // Restore funds if transfer fails
                    houseFunds[gameID] += amount;
                    totalEarnings[gameID][player] -= amount;
                    gameTotalRewards[gameID] -= amount;
                    gameTotalClaimed[gameID] -= amount;
                    revert TransferFailed();
                }
            }
            
            emit EarningsClaimed(gameID, player, amount);
        }

        // Update leaderboard stats if leaderboard contract is set and score provided
        if (leaderboardContract != address(0) && score > 0) {
            IOnchainGameLeaderboard(leaderboardContract).updatePlayerStats(gameID, player, score);
        }
    }
    
    /**
     * @dev Pay jackpot to winner (called by leaderboard contract)
     * @param gameID ID of the game
     * @param winner Player who won jackpot
     * @return Jackpot amount paid
     */
    function payJackpot(uint256 gameID, address winner) 
        external 
        returns (uint256)
    {
        // Only leaderboard contract can trigger jackpot payments
        if (msg.sender != leaderboardContract) revert Unauthorized();
        
        // Verify game exists
        if (!IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }

        // Get jackpot configuration from leaderboard contract
        (uint256 duration, , ) = IOnchainGameLeaderboard(leaderboardContract).getJackpotConfig(gameID);
        
        if (duration == 0) return 0; // No jackpot configured
        
        // Calculate actual jackpot payout (90% of accumulated jackpot funds)
        uint256 totalJackpotFunds = jackpotFunds[gameID];
        if (totalJackpotFunds == 0) return 0; // No jackpot funds available
        
        uint256 jackpotAmount = (totalJackpotFunds * JACKPOT_PAYOUT_PERCENTAGE) / 100;
        uint256 remainingJackpotFunds = totalJackpotFunds - jackpotAmount;
        
        // Update jackpot funds (keep 10% for next round)
        jackpotFunds[gameID] = remainingJackpotFunds;

        // Ensure we have enough jackpot funds to pay out
        if (jackpotAmount == 0) {
            return 0; // No jackpot amount to pay
        }

        gameTotalRewards[gameID] += jackpotAmount;

        // Update total claimed for this game
        gameTotalClaimed[gameID] += jackpotAmount;

        // Get game info to determine token type
        (,, address tokenAddress, , bool useNativeToken, , ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);
        
        // Transfer jackpot directly to winner
        if (useNativeToken) {
            // Transfer native tokens (ETH)
            (bool success, ) = payable(winner).call{value: jackpotAmount}("");
            if (!success) {
                // Restore balances if transfer fails
                jackpotFunds[gameID] = totalJackpotFunds;
                gameTotalRewards[gameID] -= jackpotAmount;
                gameTotalClaimed[gameID] -= jackpotAmount;
                return 0;
            }
        } else {
            // Transfer ERC-20 tokens
            if (!IERC20(tokenAddress).transfer(winner, jackpotAmount)) {
                // Restore balances if transfer fails
                jackpotFunds[gameID] = totalJackpotFunds;
                gameTotalRewards[gameID] -= jackpotAmount;
                gameTotalClaimed[gameID] -= jackpotAmount;
                return 0;
            }
        }

        emit JackpotPaid(gameID, winner, jackpotAmount);
        return jackpotAmount;
    }
    
    /**
     * @dev Called by authorized game contracts to record a bet and check if game has sufficient balance for max win
     * @param gameID Name of the game
     * @param player Address of the player
     * @param betAmount Amount being bet
     * @param maxWinMultiplier Maximum win multiplier (e.g., 10 for 10x max win)
     */
    function recordBetAndCheckBalance(uint256 gameID, address player, uint256 betAmount, uint256 maxWinMultiplier) external payable override {
        // Verify the game exists and caller is authorized
        _verifyGameAndAuthorization(gameID);

        // Get game info from the main contract
        (,, address tokenAddress, , bool useNativeToken,, ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);

        // Check bet is valid
        if (!IOnchainGameManager(onchainGameManager).isValidBet(gameID, betAmount)) {
            revert InvalidTokenConfiguration();
        }

        // Handle payment and distribute fees
        if (useNativeToken) {
            // For native token, msg.value must equal betAmount
            if (msg.value != betAmount) revert InvalidTokenConfiguration();
            _distributeFees(gameID, betAmount);
        } else {
            // For ERC20, transfer from player to this contract
            if (!IERC20(tokenAddress).transferFrom(player, address(this), betAmount)) {
                revert TransferFailed();
            }
            _distributeFees(gameID, betAmount);
        }

        uint256 maxWin = betAmount * maxWinMultiplier;
        
        // Check if house has sufficient funds for maximum possible win
        if (houseFunds[gameID] < maxWin) {
            revert InsufficientFunds(gameID, "house", maxWin, houseFunds[gameID]);
        }

        // Record the bet in the game stats
        gameTotalBets[gameID] += betAmount;
    }
    

    
    /**
     * @dev Fund the jackpot of a specific game with tokens/ETH (anyone can fund)
     * @param gameID ID of the game to fund jackpot for
     * @param amount Amount to add to jackpot
     */
    function fundJackpot(uint256 gameID, uint256 amount) external payable nonReentrant {
        // Verify game exists
        if (!IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }
        
        // Get game info
        (,, address tokenAddress, , bool useNativeToken, , ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);
        
        // Anyone can fund the jackpot
        
        if (useNativeToken) {
            // For native tokens, msg.value should equal amount
            if (msg.value != amount) revert InvalidTokenConfiguration();
            jackpotFunds[gameID] += amount;
        } else {
            // For ERC20 tokens, transfer from sender to this contract
            if (!IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount)) {
                revert TransferFailed();
            }
            jackpotFunds[gameID] += amount;
        }

        emit JackpotFunded(gameID, msg.sender, amount);
    }

    /**
     * @dev Fund a specific game with tokens/ETH (anyone can fund)
     * @param gameID ID of the game to fund
     * @param amount Amount to deposit
     */
    function fundGame(uint256 gameID, uint256 amount) external payable nonReentrant {
        // Verify game exists
        if (!IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }
        
        // Get game info
        (,, address tokenAddress, , bool useNativeToken, , ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);
        
        // Anyone can fund the game (removed authorization check)
        
        if (useNativeToken) {
            // For native tokens, msg.value should equal amount
            if (msg.value != amount) revert InvalidTokenConfiguration();
            houseFunds[gameID] += amount;
        } else {
            // For ERC20 tokens, transfer from sender to this contract
            if (!IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount)) {
                revert TransferFailed();
            }
            houseFunds[gameID] += amount;
        }
        gameTotalFunded[gameID] += amount;

        emit GameFunded(gameID, msg.sender, amount);
    }
    
    /**
     * @dev Withdraw excess funds from a specific game (only game creator or owner)
     * @param gameID Name of the game
     * @param amount Amount to withdraw
     * @param to Address to send funds to
     */
    function withdrawGameFunds(uint256 gameID, uint256 amount, address to) external nonReentrant {
        // Verify game exists
        if (!IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }
        if (to == address(0)) revert ZeroAddress();
        
        // Get game info
        (,, address tokenAddress, , bool useNativeToken, address creator, ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);
        
        // Only game creator or contract owner can withdraw
        if (msg.sender != creator && msg.sender != owner()) revert Unauthorized();
        
        // Check if there are sufficient house funds (creators can only withdraw their own funds)
        if (houseFunds[gameID] < amount) {
            revert InsufficientFunds(gameID, "house", amount, houseFunds[gameID]);
        }
        
        // Deduct from house funds only
        houseFunds[gameID] -= amount;
        
        // Transfer funds
        if (useNativeToken) {
            (bool success, ) = payable(to).call{value: amount}("");
            if (!success) {
                // Restore balance if transfer fails
                houseFunds[gameID] += amount;
                revert TransferFailed();
            }
        } else {
            if (!IERC20(tokenAddress).transfer(to, amount)) {
                // Restore balance if transfer fails
                houseFunds[gameID] += amount;
                revert TransferFailed();
            }
        }

        emit GameFundsWithdrawn(gameID, msg.sender, to, amount);
    }
    
    /**
     * @dev Get the current balance of a game
     * @param gameID Name of the game
     * @return Current game balance (house funds)
     */
    function getGameBalance(uint256 gameID) external returns (uint256) {
        return houseFunds[gameID];
    }
    
    /**
     * @dev Get pending earnings for a player in a specific game
     * @param gameID Name of the game
     * @param player Address of the player
     * @return Pending earnings amount (always 0 - handled by game contracts now)
     */
    function getPendingEarnings(uint256 gameID, address player) external pure returns (uint256) {
        // Pending earnings are now handled by individual game contracts
        return 0;
    }
    
    /**
     * @dev Get total earnings for a player in a specific game
     * @param gameID Name of the game
     * @param player Address of the player
     * @return Total earnings amount
     */
    function getTotalEarnings(uint256 gameID, address player) external view returns (uint256) {
        return totalEarnings[gameID][player];
    }
    
    /**
     * @dev Get owner earnings for a specific game (ETH or ERC20)
     * @param gameID ID of the game
     * @return Amount of fees available for withdrawal
     */
    function getOwnerEarnings(uint256 gameID) external view returns (uint256) {
        return ownerFeesEscrow[gameID];
    }
    
    /**
     * @dev Get fee receiver address
     * @return Address that receives owner fees
     */
    function getFeeReceiver() external view returns (address) {
        return feeReceiver;
    }
    
    /**
     * @dev Get current owner fee percentage
     * @return Current owner fee percentage (0-100)
     */
    function getOwnerFeePercentage() external view returns (uint256) {
        return ownerFeePercentage;
    }
    
    /**
     * @dev Get current jackpot contribution percentage
     * @return Current jackpot contribution percentage (0-100)
     */
    function getJackpotContributionPercentage() external view returns (uint256) {
        return jackpotContributionPercentage;
    }
    
    /**
     * @dev Get accumulated jackpot amount for a game
     * @param gameID ID of the game
     * @return Current jackpot fund balance
     */
    function getAccumulatedJackpot(uint256 gameID) external view returns (uint256) {
        return jackpotFunds[gameID];
    }
    
    /**
     * @dev Get the actual jackpot payout amount (90% of accumulated)
     * @param gameID ID of the game
     * @return Amount that would be paid out if jackpot is won
     */
    function getJackpotPayoutAmount(uint256 gameID) external view returns (uint256) {
        return (jackpotFunds[gameID] * JACKPOT_PAYOUT_PERCENTAGE) / 100;
    }
    
    /**
     * @dev Get complete fund breakdown for a game
     * @param gameID ID of the game
     * @return houseFunds_ House funds available
     * @return pendingEarnings_ Total pending player earnings (always 0 - handled by games now)
     * @return jackpotFunds_ Accumulated jackpot funds
     * @return ownerFees_ Owner fees available for withdrawal
     * @return totalBalance_ Sum of all funds
     */
    function getGameFundBreakdown(uint256 gameID) external view returns (
        uint256 houseFunds_,
        uint256 pendingEarnings_,
        uint256 jackpotFunds_,
        uint256 ownerFees_,
        uint256 totalBalance_
    ) {
        houseFunds_ = houseFunds[gameID];
        pendingEarnings_ = 0; // Pending earnings now handled by individual game contracts
        jackpotFunds_ = jackpotFunds[gameID];
        ownerFees_ = ownerFeesEscrow[gameID];
        totalBalance_ = houseFunds_ + jackpotFunds_ + ownerFees_;
    }
    
    /**
     * @dev Get total amount claimed from a specific game
     * @param gameID Name of the game
     * @return Total amount claimed from the game
     */
    function getGameTotalClaimed(uint256 gameID) external view returns (uint256) {
        return gameTotalClaimed[gameID];
    }
    
    /**
     * @dev Get total bets for a specific game
     * @param gameID Name of the game
     * @return Total bets amount
     */
    function getGameTotalBets(uint256 gameID) external view returns (uint256) {
        return gameTotalBets[gameID];
    }
    
    /**
     * @dev Get total rewards for a specific game
     * @param gameID Name of the game
     * @return Total rewards amount
     */
    function getGameTotalRewards(uint256 gameID) external view returns (uint256) {
        return gameTotalRewards[gameID];
    }
    


    /**
     * @dev Allows the owner to withdraw all ETH from the contract
     * @param to Address to send the ETH to
     */
    function flushETH(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool success, ) = to.call{value: address(this).balance}("");
        if (!success) revert TransferFailed();
    }
    
    /**
     * @dev Allows fee receiver to withdraw accumulated owner fees for a specific game
     * @param gameID Name of the game to withdraw owner fees from
     */
    function withdrawOwnerFees(uint256 gameID) external nonReentrant {
        // Verify game exists
        if (!IOnchainGameManager(onchainGameManager).gameExists(gameID)) {
            revert GameNotFound(gameID);
        }
        
        if (msg.sender != feeReceiver && msg.sender != owner()) revert Unauthorized();
        
        uint256 amount = ownerFeesEscrow[gameID];
        if (amount == 0) revert NoFeesToWithdraw();
        
        // Reset earnings before transfer
        ownerFeesEscrow[gameID] = 0;
        
        // Update total claimed for this game
        gameTotalClaimed[gameID] += amount;
        
        // Get game info to determine token type
        (,, address tokenAddress, , bool useNativeToken, , ) = IOnchainGameManager(onchainGameManager).getGameInfo(gameID);
        
        // Transfer fees to fee receiver
        if (useNativeToken) {
            (bool success, ) = payable(feeReceiver).call{value: amount}("");
            if (!success) {
                // Restore earnings if transfer fails
                ownerFeesEscrow[gameID] = amount;
                gameTotalClaimed[gameID] -= amount;
                revert TransferFailed();
            }
        } else {
            if (!IERC20(tokenAddress).transfer(feeReceiver, amount)) {
                // Restore earnings if transfer fails
                ownerFeesEscrow[gameID] = amount;
                gameTotalClaimed[gameID] -= amount;
                revert TransferFailed();
            }
        }
        
        emit OwnerFeesWithdrawn(feeReceiver, amount);
    }
    
    /**
     * @dev Internal function to distribute funds from a bet
     * @param gameID ID of the game
     * @param betAmount Total bet amount
     */
    function _distributeFees(uint256 gameID, uint256 betAmount) internal {
        // Calculate fund distribution (no creator fees)
        uint256 ownerAmount = (betAmount * ownerFeePercentage) / 100;
        uint256 jackpotAmount = (betAmount * jackpotContributionPercentage) / 100;
        uint256 houseAmount = betAmount - ownerAmount - jackpotAmount;
        
        // Distribute funds to separate accounts
        houseFunds[gameID] += houseAmount;
        ownerFeesEscrow[gameID] += ownerAmount;
        jackpotFunds[gameID] += jackpotAmount;
        
        emit FundsDistributed(gameID, houseAmount, ownerAmount, jackpotAmount);
    }
    
    /**
     * @dev Internal function to verify game exists and caller is authorized
     * @param gameID Name of the game to verify
     */
    function _verifyGameAndAuthorization(uint256 gameID) internal view {
        if (onchainGameManager == address(0)) revert Unauthorized();
        
        // Check if the caller is the authorized contract for this game type
        address gameTypeContract = IOnchainGameManager(onchainGameManager).getGameTypeContract(gameID);
        if (msg.sender != gameTypeContract) revert Unauthorized();
    }
    
    /**
     * @dev Receive function to accept ETH from game contracts for bets
     */
    receive() external payable {
        // ETH received from game contracts for bets
        // No additional logic needed, just accept the ETH
    }
}
