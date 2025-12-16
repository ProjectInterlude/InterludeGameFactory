// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./IOnchainGameManager.sol";
import "./IOnchainGameEarnings.sol";
import "./IOnchainGameLeaderboard.sol";
import "./ITokenWhitelist.sol";

/**
 * @title OnchainGameManager
 * @dev Core registry contract that manages game types and instances
 * @notice This contract serves as the central registry for all onchain games
 */
contract OnchainGameManager is IOnchainGameManager, Ownable {
    
    // Mapping from game type name to game type data
    mapping(string => GameType) public gameTypes;
    
    // Array to keep track of all game type names
    string[] public gameTypeNames;
    
    // Mapping from game IDs to game data
    mapping(uint256 => GameInfo) public games;
    uint256 public gameCount;

    // Mapping to check if bet amount is valid for a specific game
    mapping(uint256 => mapping(uint256 => bool)) public gameValidBets;
    
    // Global setting to control whether game creation requires authorization
    bool public restrictGameCreation;
    
    // Whitelist for game creation authorization (only used when restrictGameCreation is true)
    mapping(address => bool) public authorizedCreators;
    
    // External contract addresses
    address public override earningsContract;
    address public override leaderboardContract;
    address public override jackpotManager; // Deprecated - now handled by leaderboard
    address public override tokenWhitelist;
    
    // Custom errors for gas efficiency
    error GameTypeNotFound(string gameTypeName);
    error GameTypeAlreadyExists(string gameTypeName);
    error GameNotFound(uint256 gameID);
    error GameAlreadyExists(uint256 gameID);
    error ZeroAddress();
    error EmptygameID();
    error EmptyBetList();
    error Unauthorized();
    error NotAuthorizedCreator();
    error InsufficientGameCreationFee(uint256 required, uint256 provided);
    error NativeTokenNotAllowed(string gameTypeName);
    error InvalidTokenConfiguration();

    /**
     * @dev Constructor sets the initial owner
     */
        constructor() Ownable() {
        // Initial setup - contracts linked via setters after deployment
        // Initially, game creation is unrestricted (anyone can create games)
        restrictGameCreation = false;
        // Owner is automatically authorized to create games
        authorizedCreators[msg.sender] = true;
    }
    
    /**
     * @dev Register a new game type (contract template)
     * @param gameTypeName Unique name for the game type
     * @param contractAddress Address of the game type contract
     * @param gameCreationFee Fee required to create games of this type
     * @param allowBetInNativeToken Whether this game type allows onchain with native tokens
     */
    function registerGameType(
        string calldata gameTypeName,
        address contractAddress,
        uint256 gameCreationFee,
        bool allowBetInNativeToken
    ) external override onlyOwner {
        if (bytes(gameTypeName).length == 0) revert EmptygameID();
        if (contractAddress == address(0)) revert ZeroAddress();
        if (gameTypes[gameTypeName].contractAddress != address(0)) revert GameTypeAlreadyExists(gameTypeName);
        
        // Initialize the game type
        GameType storage newGameType = gameTypes[gameTypeName];
        newGameType.contractAddress = contractAddress;
        newGameType.typeName = gameTypeName;
        newGameType.gameCreationFee = gameCreationFee;
        newGameType.allowBetInNativeToken = allowBetInNativeToken;
        
        // Add to game type names array
        gameTypeNames.push(gameTypeName);
    }

    /**
     * @dev Creates a new onchain game instance
     * @param params GameCreationParams struct containing all game parameters
     */
    function createGame(GameCreationParams calldata params) external payable override {
        if (bytes(params.gameTypeName).length == 0) revert EmptygameID();
        if (params.allowedBets.length == 0) revert EmptyBetList();
        if (gameTypes[params.gameTypeName].contractAddress == address(0)) revert GameTypeNotFound(params.gameTypeName);
        
        // Only check authorization if game creation is restricted
        if (restrictGameCreation && !authorizedCreators[msg.sender]) revert NotAuthorizedCreator();

        bool exists = (params.gameID != 0);

        if (exists) {
            GameInfo storage game = games[params.gameID];
            // Update situation
            if (msg.sender != game.creator && msg.sender != owner()) revert Unauthorized();

            game.allowedBets = params.allowedBets;

            // Reset and update valid bets mapping
            for (uint256 i = 0; i < params.allowedBets.length; i++) {
                if (params.allowedBets[i] > 0) {
                    gameValidBets[params.gameID][params.allowedBets[i]] = true;
                }
            }

            emit GameCreated(params.gameID, msg.sender, params.gameTypeName, params.tokenAddress, params.allowedBets[0], params.useNativeToken, true);
            return;
        }
        // Creation situation
        _createNewGame(params);
    }

    /**
     * @dev Internal function to create a new game
     */
    function _createNewGame(GameCreationParams calldata params) internal {

        uint256 gameID = ++gameCount;

        GameType storage gameType = gameTypes[params.gameTypeName];

        // Validate native token configuration
        if (params.useNativeToken) {
            if (!gameType.allowBetInNativeToken) revert NativeTokenNotAllowed(params.gameTypeName);
            if (params.tokenAddress != address(0)) revert InvalidTokenConfiguration();
        } else {
            if (params.tokenAddress == address(0)) revert InvalidTokenConfiguration();
        }

        // Check if token is whitelisted to skip fee (only for ERC-20 tokens)
        bool tokenIsWhitelisted = false;
        if (!params.useNativeToken && tokenWhitelist != address(0)) {
            tokenIsWhitelisted = ITokenWhitelist(tokenWhitelist).isWhitelisted(params.tokenAddress);
        }

        // Apply fee only if token is not whitelisted
        if (!tokenIsWhitelisted && msg.value < gameType.gameCreationFee) {
            revert InsufficientGameCreationFee(gameType.gameCreationFee, msg.value);
        }

        // Initialize the game
        GameInfo storage newGame = games[gameID];
        newGame.gameName = params.gameName;
        newGame.gameType = params.gameTypeName;
        newGame.useNativeToken = params.useNativeToken;
        newGame.allowedBets = params.allowedBets;
        newGame.rewardToken = params.tokenAddress;
        newGame.creator = (params.creator == address(0)) ? msg.sender : params.creator;

        // Set up valid bets mapping from the provided array
        for (uint256 i = 0; i < params.allowedBets.length; i++) {
            if (params.allowedBets[i] > 0) {
                gameValidBets[gameID][params.allowedBets[i]] = true;
            }
        }


        // Configure jackpot if enabled and leaderboard contract is set
        if (params.jackpotEnabled && leaderboardContract != address(0)) {

            IOnchainGameLeaderboard(leaderboardContract).configureJackpot(params.gameID, params.jackpotDuration, params.jackpotTopPlayers);
        }

        emit GameCreated(gameID, msg.sender, params.gameTypeName, params.tokenAddress, params.allowedBets[0], params.useNativeToken, false);
    }
    
    /**
     * @dev Delete a game (only owner)
     * @param gameID Name of the game to delete
     */
    function deleteGame(uint256 gameID) external override onlyOwner {
        GameInfo storage game = games[gameID];
        
        if (game.creator == address(0)) revert GameNotFound(gameID);
        
        // Delete the game
        delete games[gameID];
        
        emit GameDeleted(gameID, msg.sender);
    }
    
    /**
     * @dev Transfer ownership of a game to a new address
     * @param gameID ID of the game to transfer
     * @param newOwner Address of the new owner
     */
    function transferGameOwnership(uint256 gameID, address newOwner) external override {
        GameInfo storage game = games[gameID];
        
        if (game.creator == address(0)) revert GameNotFound(gameID);
        if (newOwner == address(0)) revert ZeroAddress();
        
        // Only current game creator or contract owner can transfer ownership
        if (msg.sender != game.creator && msg.sender != owner()) revert Unauthorized();
        
        address previousOwner = game.creator;
        game.creator = newOwner;
        
        emit GameOwnershipTransferred(gameID, previousOwner, newOwner);
    }
    
    /**
     * @dev Set the earnings contract address (only owner)
     * @param _earningsContract Address of the earnings contract
     */
    function setEarningsContract(address _earningsContract) external override onlyOwner {
        earningsContract = _earningsContract;
    }
    
    /**
     * @dev Set the leaderboard contract address (only owner)
     * @param _leaderboardContract Address of the leaderboard contract
     */
    function setLeaderboardContract(address _leaderboardContract) external override onlyOwner {
        leaderboardContract = _leaderboardContract;
    }
    
    /**
     * @dev Set the jackpot manager contract (only owner) - DEPRECATED
     * @param _jackpotManager Address of the jackpot manager contract (ignored)
     */
    function setJackpotManager(address _jackpotManager) external override onlyOwner {
        // This function is kept for interface compatibility but does nothing
        // since jackpot functionality is now handled by the leaderboard contract
        jackpotManager = _jackpotManager; // Keep for backward compatibility
    }
    
    /**
     * @dev Set the token whitelist contract (only owner)
     * @param whitelistContract Address of the token whitelist contract
     */
    function setTokenWhitelist(address whitelistContract) external override onlyOwner {
        tokenWhitelist = whitelistContract;
    }
    
    /**
     * @dev Set the fee required to create games of a specific type (only owner)
     * @param gameTypeName Name of the game type
     * @param newFee New fee amount in wei (ETH)
     */
    function setGameTypeCreationFee(string calldata gameTypeName, uint256 newFee) external override onlyOwner {
        GameType storage gameType = gameTypes[gameTypeName];
        if (gameType.contractAddress == address(0)) revert GameTypeNotFound(gameTypeName);
        
        gameType.gameCreationFee = newFee;
    }
    
    /**
     * @dev Set whether a game type allows native token onchain (only owner)
     * @param gameTypeName Name of the game type
     * @param allowNativeToken Whether to allow native token onchain
     */
    function setGameTypeNativeTokenSupport(string calldata gameTypeName, bool allowNativeToken) external override onlyOwner {
        GameType storage gameType = gameTypes[gameTypeName];
        if (gameType.contractAddress == address(0)) revert GameTypeNotFound(gameTypeName);
        
        gameType.allowBetInNativeToken = allowNativeToken;
    }
    
    /**
     * @dev Update the contract address for a game type (only owner)
     * @param gameTypeName Name of the game type to update
     * @param newContractAddress New contract address
     */
    function updateGameTypeContract(string calldata gameTypeName, address newContractAddress) external override onlyOwner {
        if (newContractAddress == address(0)) revert ZeroAddress();
        
        GameType storage gameType = gameTypes[gameTypeName];
        if (gameType.contractAddress == address(0)) revert GameTypeNotFound(gameTypeName);
        
        // Update to new contract
        gameType.contractAddress = newContractAddress;
    }
    
    /**
     * @dev Authorize or deauthorize an address to create games (only owner)
     * @param creator Address to authorize/deauthorize
     * @param authorized Whether the address should be authorized
     */
    function setCreatorAuthorization(address creator, bool authorized) external override onlyOwner {
        if (creator == address(0)) revert ZeroAddress();
        
        authorizedCreators[creator] = authorized;
        emit CreatorAuthorized(creator, authorized);
    }
    
    /**
     * @dev Set whether game creation requires authorization (only owner)
     * @param restricted If true, only authorized addresses can create games; if false, anyone can create games
     */
    function setGameCreationRestricted(bool restricted) external onlyOwner {
        restrictGameCreation = restricted;
    }
    
    
    // VIEW FUNCTIONS
    
    /**
     * @dev Get game information
     */
    function getGameInfo(uint256 gameID) external view override returns (
        string memory gameName,
        address gameTypeContract,
        address tokenAddress,
        uint256[] memory allowedBets,
        bool useNativeToken,
        address creator,
        string memory gameType
    ) {
        GameInfo storage game = games[gameID];
        if (game.creator == address(0)) revert GameNotFound(gameID);
        
        GameType storage gameTypeInfo = gameTypes[game.gameType];
        
        return (
            game.gameName,
            gameTypeInfo.contractAddress,
            game.rewardToken,
            game.allowedBets,
            game.useNativeToken,
            game.creator,
            game.gameType
        );
    }
    
    /**
     * @dev Check if a bet amount is valid for a specific game
     * @param gameID Name of the game
     * @param betAmount Bet amount to validate
     * @return True if the bet amount is valid
     */
    function isValidBet(uint256 gameID, uint256 betAmount) external view override returns (bool) {
        GameInfo storage game = games[gameID];
        if (game.creator == address(0)) return false;
        
        return gameValidBets[gameID][betAmount];
    }
    
    /**
     * @dev Check if an address is authorized to create games
     * @param creator Address to check
     * @return bool True if the address is authorized
     */
    function isAuthorizedCreator(address creator) external view override returns (bool) {
        return authorizedCreators[creator];
    }
    
    /**
     * @dev Get game type information
     */
    function getGameTypeInfo(string calldata gameTypeName) external view override returns (
        address contractAddress,
        uint256 gameCreationFee,
        bool allowBetInNativeToken
    ) {
        GameType storage gameType = gameTypes[gameTypeName];
        if (gameType.contractAddress == address(0)) revert GameTypeNotFound(gameTypeName);
        
        return (
            gameType.contractAddress,
            gameType.gameCreationFee,
            gameType.allowBetInNativeToken
        );
    }
    
    /**
     * @dev Get all registered game type names
     * @return Array of all game type names
     */
    function getAllGameTypeNames() external view override returns (string[] memory) {
        return gameTypeNames;
    }
    
    /**
     * @dev Check if game exists
     * @param gameID Name of the game to check
     * @return True if the game exists
     */
    function gameExists(uint256 gameID) external view returns (bool) {
        return games[gameID].creator != address(0);
    }
    
    /**
     * @dev Get game creator
     * @param gameID Name of the game
     * @return Address of the game creator
     */
    function getGameCreator(uint256 gameID) external view returns (address) {
        GameInfo storage game = games[gameID];
        if (game.creator == address(0)) revert GameNotFound(gameID);
        return game.creator;
    }
    
    /**
     * @dev Get game type contract for a specific game
     * @param gameID Name of the game
     * @return Address of the game type contract
     */
    function getGameTypeContract(uint256 gameID) external view returns (address) {
        GameInfo storage game = games[gameID];
        if (game.creator == address(0)) revert GameNotFound(gameID);
        
        GameType storage gameType = gameTypes[game.gameType];
        return gameType.contractAddress;
    }
    
    /**
     * @dev Receive function to accept ETH for game creation fees
     */
    receive() external payable {
        // Accept ETH for game creation fees
    }
}
