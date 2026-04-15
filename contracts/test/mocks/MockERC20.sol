// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  MockERC20 — minimal ERC20 with EIP-2612 permit
/// @notice Matches the on-chain USDC surface (ERC20 + EIP-2612), which is what
///         the router integrates against via `IERC20Permit(address(USDC)).permit(...)`
///         in `depositWithPermit`. Also exposes `mint` / `burn` / `setBalance`
///         for test seeding.
contract MockERC20 {
    // ── ERC20 ────────────────────────────────────────────────────────────────

    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ── EIP-2612 permit ──────────────────────────────────────────────────────

    /// @dev EIP-2612 per-owner nonce. Incremented inside `permit()` so a given
    ///      signature is usable exactly once.
    mapping(address => uint256) public nonces;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    error PermitDeadlineExpired();
    error PermitInvalidSigner();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        _HASHED_NAME = keccak256(bytes(name_));
        _HASHED_VERSION = keccak256(bytes("1"));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice EIP-712 domain separator. Recomputed if chainid changes (fork).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) return _CACHED_DOMAIN_SEPARATOR;
        return _buildDomainSeparator();
    }

    function _buildDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    /// @notice EIP-2612 permit. Consumes the owner's nonce on every call (even
    ///         on failure via checks-then-increment is NOT done here — increment
    ///         is part of the struct hash, so a failed recovery simply reverts
    ///         without mutating state). Matches the canonical USDC semantics.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert PermitDeadlineExpired();

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner], deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != owner) revert PermitInvalidSigner();

        // Only consume the nonce once we're committing to the allowance update.
        // This ordering matches OpenZeppelin ERC20Permit: failed signatures do
        // NOT burn a nonce.
        unchecked {
            nonces[owner] = nonces[owner] + 1;
        }

        allowance[owner][spender] = value;
    }

    // ── Test seeding helpers ─────────────────────────────────────────────────

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setBalance(address account, uint256 newBalance) external {
        uint256 oldBalance = balanceOf[account];

        if (newBalance >= oldBalance) {
            totalSupply += newBalance - oldBalance;
        } else {
            totalSupply -= oldBalance - newBalance;
        }

        balanceOf[account] = newBalance;
    }
}
