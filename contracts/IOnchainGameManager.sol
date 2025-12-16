// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOnchainGameManager
 * @dev Interface for the core onchain game manager
 */
interface IOnchainGameManager {
    
    // Struct to hold information about a game type (contract template)
    struct GameType {
        address contractAddress;
        string typeName;
        uint256 gameCreationFee;
        bool allowBetInNativeToken;
    }
    
    // Basic game info struct (without mappings)
    struct GameInfo {
        string gameName;
        string gameType;
        address rewardToken;
        uint256[] allowedBets;
        bool useNativeToken;
        address creator;
    }
    
    // Struct for game creation parameters
    struct GameCreationParams {
        uint256 gameID;
        string gameName;
        string gameTypeName;
        address tokenAddress;
        uint256[] allowedBets;
        bool useNativeToken;
        address creator;
        bool jackpotEnabled;
        uint256 jackpotDuration;
        uint256 jackpotTopPlayers;
    }
    
    // Events
    event GameCreated(
        uint256 indexed gameID, 
        address indexed creator, 
        string indexed gameType,
        address tokenAddress, 
        uint256 minimalBet,
        bool useNativeToken,
        bool isUpdate
    );
    event GameDeleted(uint256 indexed gameID, address indexed deletedBy);
    event GameOwnershipTransferred(uint256 indexed gameID, address indexed previousOwner, address indexed newOwner);
    event CreatorAuthorized(address indexed creator, bool authorized);
    
    // Game management functions
    function registerGameType(
        string calldata gameTypeName,
        address contractAddress,
        uint256 gameCreationFee,
        bool allowBetInNativeToken
    ) external;
    
    function createGame(GameCreationParams calldata params) external payable;
    function deleteGame(uint256 gameID) external;
    function transferGameOwnership(uint256 gameID, address newOwner) external;
    
    // Authorization functions
    function setCreatorAuthorization(address creator, bool authorized) external;
    function setGameCreationRestricted(bool restricted) external;
    function isAuthorizedCreator(address creator) external view returns (bool);
    
    // Game type management
    function updateGameTypeContract(string calldata gameTypeName, address newContractAddress) external;
    function setGameTypeCreationFee(string calldata gameTypeName, uint256 newFee) external;
    function setGameTypeNativeTokenSupport(string calldata gameTypeName, bool allowNativeToken) external;
    
    // View functions
    function getGameInfo(uint256 gameID) external view returns (
        string memory gameName,
        address gameTypeContract,
        address tokenAddress,
        uint256[] memory allowedBets,
        bool useNativeToken,
        address creator,
        string memory gameType
    );
    
    function getGameTypeInfo(string calldata gameTypeName) external view returns (
        address contractAddress,
        uint256 gameCreationFee,
        bool allowBetInNativeToken
    );
    
    function isValidBet(uint256 gameID, uint256 betAmount) external view returns (bool);
    function gameExists(uint256 gameID) external view returns (bool);
    function getGameTypeContract(uint256 gameID) external view returns (address);
    function getGameCreator(uint256 gameID) external view returns (address);
    function getAllGameTypeNames() external view returns (string[] memory);
    
    // Contract management
    function setEarningsContract(address _earningsContract) external;
    function setLeaderboardContract(address _leaderboardContract) external;
    function setJackpotManager(address _jackpotManager) external;
    function setTokenWhitelist(address whitelistContract) external;
    
    // External contract addresses
    function earningsContract() external view returns (address);
    function leaderboardContract() external view returns (address);
    function jackpotManager() external view returns (address);
    function tokenWhitelist() external view returns (address);
}
