// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ITokenWhitelist
 * @dev Interface for token whitelist management
 */
interface ITokenWhitelist {
    
    // Events
    event TokenWhitelisted(address indexed token, bool whitelisted);
    
    // Core functions
    function isWhitelisted(address token) external view returns (bool);
    function whitelistToken(address token, bool whitelisted) external;
    function getWhitelistedTokens() external view returns (address[] memory);
    
    // Administrative functions
    function addToWhitelist(address token) external;
    function removeFromWhitelist(address token) external;
}
