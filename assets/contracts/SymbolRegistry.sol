// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SymbolRegistry
/// @author ruzkypazzy
/// @notice On-chain registry of token-symbol claims on Pharos. Complements the
///         off-chain PSCD scanner: while PSCD detects ERC-20 mints that already
///         use a symbol on Pharos, this contract lets a developer record an
///         explicit, time-stamped claim to a symbol with a refundable PHRS
///         deposit. Anyone can query the registry to see if a symbol is
///         already claimed, and the original claimer can release the claim
///         to recover the deposit.
///
/// @dev    Deployed to both Pharos Atlantic Testnet (688689) and Pharos Pacific
///         Mainnet (1672). Same contract source; deployment address lives in
///         `assets/networks.json` so the agent layer can pick the right one.
contract SymbolRegistry {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Claim {
        address claimer;       // address that posted the claim
        uint256 deposit;       // refundable PHRS deposit (wei)
        uint64 timestamp;      // block.timestamp of the claim
        uint64 blockNumber;    // block number of the claim
        string projectURI;     // optional project URL / contact (free-form)
        bool active;           // true until released
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice Contract owner (deployer). The only address that can pause
    ///         the contract or run an emergency withdrawal. The owner has
    ///         NO power to steal active claims.
    address public owner;

    /// @notice Paused state. When true, register() and release() revert.
    bool public paused;

    /// @notice Required deposit in wei (0.001 PHRS / PROS). Refundable.
    uint256 public constant MIN_DEPOSIT = 0.001 ether;

    /// @notice keccak256(normalized symbol) => Claim
    mapping(bytes32 => Claim) public claims;

    /// @notice Per-claimer history (does not include released entries, which
    ///         are kept in `claims` with active=false).
    mapping(address => bytes32[]) public byClaimer;

    /// @notice Convenience counter for total active claims.
    uint256 public activeClaimCount;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event SymbolRegistered(
        bytes32 indexed symbolHash,
        string symbol,
        address indexed claimer,
        uint256 deposit,
        uint64 timestamp,
        uint64 blockNumber,
        string projectURI
    );

    event SymbolReleased(
        bytes32 indexed symbolHash,
        string symbol,
        address indexed claimer,
        uint256 refund
    );

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyWithdrawal(address indexed to, uint256 amount);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error PausedState();
    error BelowMinimumDeposit();
    error AlreadyClaimed();
    error NotClaimed();
    error NotClaimer();
    error NothingToRefund();
    error TransferFailed();

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedState();
        _;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor() {
        owner = msg.sender;
        emit Unpaused(msg.sender); // start unpaused
    }

    // ------------------------------------------------------------------
    // User actions
    // ------------------------------------------------------------------

    /// @notice Register a claim to `symbol` with a refundable PHRS deposit.
    /// @param  symbol      The token symbol to claim (case-insensitive, max 32 bytes).
    /// @param  projectURI  Free-form string with project link / contact. May be empty.
    /// @return symbolHash  keccak256 of the normalized symbol.
    function register(string calldata symbol, string calldata projectURI)
        external
        payable
        whenNotPaused
        returns (bytes32 symbolHash)
    {
        if (msg.value < MIN_DEPOSIT) revert BelowMinimumDeposit();

        string memory normalized = _normalize(symbol);
        symbolHash = keccak256(bytes(normalized));

        Claim storage existing = claims[symbolHash];
        if (existing.active) revert AlreadyClaimed();

        claims[symbolHash] = Claim({
            claimer: msg.sender,
            deposit: msg.value,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number),
            projectURI: projectURI,
            active: true
        });
        byClaimer[msg.sender].push(symbolHash);
        unchecked { activeClaimCount += 1; }

        emit SymbolRegistered(
            symbolHash,
            normalized,
            msg.sender,
            msg.value,
            uint64(block.timestamp),
            uint64(block.number),
            projectURI
        );
    }

    /// @notice Release a claim the caller owns and refund the deposit in full.
    /// @param  symbol  The symbol to release (any casing; will be normalized).
    function release(string calldata symbol) external whenNotPaused {
        bytes32 symbolHash = keccak256(bytes(_normalize(symbol)));
        Claim storage c = claims[symbolHash];
        if (!c.active) revert NotClaimed();
        if (c.claimer != msg.sender) revert NotClaimer();

        c.active = false;
        uint256 refund = c.deposit;
        c.deposit = 0;
        unchecked { activeClaimCount -= 1; }

        (bool ok, ) = payable(msg.sender).call{value: refund}("");
        if (!ok) revert TransferFailed();

        emit SymbolReleased(symbolHash, symbol, msg.sender, refund);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Returns true if the (normalized) symbol has an active claim.
    function isClaimed(string calldata symbol) external view returns (bool) {
        return claims[keccak256(bytes(_normalize(symbol)))].active;
    }

    /// @notice Returns the full Claim record for a symbol.
    function getClaim(string calldata symbol) external view returns (Claim memory) {
        return claims[keccak256(bytes(_normalize(symbol)))];
    }

    /// @notice Returns the count of symbols currently claimed by `claimer`.
    function activeClaimCountOf(address claimer) external view returns (uint256) {
        bytes32[] storage ids = byClaimer[claimer];
        uint256 n;
        unchecked {
            for (uint256 i; i < ids.length; ++i) {
                if (claims[ids[i]].active) ++n;
            }
        }
        return n;
    }

    /// @notice Returns the contract's PHRS balance (sum of active deposits minus withdrawals).
    function totalHeld() external view returns (uint256) {
        return address(this).balance;
    }

    // ------------------------------------------------------------------
    // Owner controls (safety only — does not affect active claims)
    // ------------------------------------------------------------------

    /// @notice Pause new registrations and releases. Existing claims remain
    ///         refundable via release() — except release() also reverts while
    ///         paused, so use emergencyWithdrawal() to refund the owner
    ///         (NOT individual claimers) in a true emergency.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Withdraw ALL held PHRS to the owner. Intended as an emergency
    ///         recovery hatch if the contract is somehow corrupted. The owner
    ///         is expected to manually refund any active claimers off-chain
    ///         using the SymbolRegistered event log.
    function emergencyWithdrawal() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToRefund();
        (bool ok, ) = payable(owner).call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit EmergencyWithdrawal(owner, bal);
    }

    /// @notice Allow the owner to receive plain transfers (e.g. direct top-ups).
    receive() external payable {}
    fallback() external payable {}

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Strip whitespace and uppercase ASCII letters. Other Unicode is
    ///      preserved as-is — exact-match only. Limit 32 bytes to match the
    ///      ERC-20 symbol() convention.
    function _normalize(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 len = b.length;
        if (len > 32) len = 32;

        bytes memory out = new bytes(len);
        uint256 j;
        for (uint256 i; i < len; ++i) {
            bytes1 c = b[i];
            if (uint8(c) == 0x20) continue; // skip space
            // ASCII a-z -> A-Z
            if (uint8(c) >= 0x61 && uint8(c) <= 0x7a) {
                c = bytes1(uint8(c) - 32);
            }
            out[j++] = c;
        }
        // trim
        bytes memory trimmed = new bytes(j);
        for (uint256 i; i < j; ++i) trimmed[i] = out[i];
        return string(trimmed);
    }
}