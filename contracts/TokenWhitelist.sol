// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./ITokenWhitelist.sol";

/**
 * @title TokenWhitelist
 * @dev Basic implementation of token whitelisting functionality
 * @notice This contract maintains a simple list of whitelisted token addresses
 */
contract TokenWhitelist is ITokenWhitelist, Ownable {
    
    // Mapping to track whitelisted token addresses
    mapping(address => bool) private _whitelistedTokens;
    
    // Array to keep track of all whitelisted tokens for enumeration
    address[] private _whitelistedTokensList;
    
    // Events
    event TokenWhitelisted(address indexed tokenAddress);
    event TokenRemovedFromWhitelist(address indexed tokenAddress);
    
    // Custom errors
    error ZeroAddress();
    error TokenAlreadyWhitelisted(address tokenAddress);
    error TokenNotWhitelisted(address tokenAddress);
    
    /**
     * @dev Constructor sets the initial owner
     */
    constructor() Ownable() {
        // Contract is ready to manage whitelist
        // In OpenZeppelin v4, msg.sender becomes owner automatically
    }
    
    /**
     * @dev Check if a token address is whitelisted
     * @param tokenAddress Address of the token to check
     * @return bool True if the token is whitelisted, false otherwise
     */
    function isWhitelisted(address tokenAddress) external view override returns (bool) {
        return _whitelistedTokens[tokenAddress];
    }
    
    /**
     * @dev Add a token to the whitelist (only owner)
     * @param tokenAddress Address of the token to whitelist
     */
    function addToWhitelist(address tokenAddress) external onlyOwner {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_whitelistedTokens[tokenAddress]) revert TokenAlreadyWhitelisted(tokenAddress);
        
        _whitelistedTokens[tokenAddress] = true;
        _whitelistedTokensList.push(tokenAddress);
        
        emit TokenWhitelisted(tokenAddress);
    }
    
    /**
     * @dev Add or remove a token from the whitelist (only owner)
     * @param tokenAddress Address of the token
     * @param whitelisted True to whitelist, false to remove from whitelist
     */
    function whitelistToken(address tokenAddress, bool whitelisted) external override onlyOwner {
        if (tokenAddress == address(0)) revert ZeroAddress();
        
        if (whitelisted) {
            if (!_whitelistedTokens[tokenAddress]) {
                _whitelistedTokens[tokenAddress] = true;
                _whitelistedTokensList.push(tokenAddress);
                emit TokenWhitelisted(tokenAddress);
            }
        } else {
            if (_whitelistedTokens[tokenAddress]) {
                _whitelistedTokens[tokenAddress] = false;
                
                // Remove from array
                for (uint256 i = 0; i < _whitelistedTokensList.length; i++) {
                    if (_whitelistedTokensList[i] == tokenAddress) {
                        _whitelistedTokensList[i] = _whitelistedTokensList[_whitelistedTokensList.length - 1];
                        _whitelistedTokensList.pop();
                        break;
                    }
                }
                
                emit TokenRemovedFromWhitelist(tokenAddress);
            }
        }
    }
    
    /**
     * @dev Remove a token from the whitelist (only owner)
     * @param tokenAddress Address of the token to remove from whitelist
     */
    function removeFromWhitelist(address tokenAddress) external onlyOwner {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (!_whitelistedTokens[tokenAddress]) revert TokenNotWhitelisted(tokenAddress);
        
        _whitelistedTokens[tokenAddress] = false;
        
        // Remove from the array
        for (uint256 i = 0; i < _whitelistedTokensList.length; i++) {
            if (_whitelistedTokensList[i] == tokenAddress) {
                // Move the last element to the deleted position and pop
                _whitelistedTokensList[i] = _whitelistedTokensList[_whitelistedTokensList.length - 1];
                _whitelistedTokensList.pop();
                break;
            }
        }
        
        emit TokenRemovedFromWhitelist(tokenAddress);
    }
    
    /**
     * @dev Add multiple tokens to the whitelist (only owner)
     * @param tokenAddresses Array of token addresses to whitelist
     */
    function addMultipleToWhitelist(address[] calldata tokenAddresses) external onlyOwner {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address tokenAddress = tokenAddresses[i];
            
            if (tokenAddress == address(0)) revert ZeroAddress();
            if (_whitelistedTokens[tokenAddress]) continue; // Skip if already whitelisted
            
            _whitelistedTokens[tokenAddress] = true;
            _whitelistedTokensList.push(tokenAddress);
            
            emit TokenWhitelisted(tokenAddress);
        }
    }
    
    /**
     * @dev Get all whitelisted token addresses
     * @return Array of whitelisted token addresses
     */
    function getWhitelistedTokens() external view override returns (address[] memory) {
        return _whitelistedTokensList;
    }
    
    /**
     * @dev Get the number of whitelisted tokens
     * @return Number of whitelisted tokens
     */
    function getWhitelistedTokensCount() external view returns (uint256) {
        return _whitelistedTokensList.length;
    }
}
