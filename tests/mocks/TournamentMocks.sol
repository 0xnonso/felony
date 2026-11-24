// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ITournament} from "../Interfaces.sol";

contract MockArena {
    struct M {
        address p0;
        address p1;
        uint256 c0;
        uint256 c1;
        uint256 tournament;
        uint256 seed;
        uint256 turn;
        uint256 result;
        bool defaulted;
        address manager;
    }
    mapping(uint256 => M) public games;
    uint256 public next;
    mapping(address => mapping(uint256 => uint256)) public first;
    mapping(address => mapping(uint256 => uint256)) public count;

    function reserveManagedMatches(uint256 tournament, uint256 size) external returns (uint256 base) {
        require(tournament != 0 && size > 0 && size <= 1024);
        require(first[msg.sender][tournament] == 0);
        base = next + 1;
        next += size;
        first[msg.sender][tournament] = base;
        count[msg.sender][tournament] = size;
    }

    function managedMatchId(address manager, uint256 tournament, uint256 index) public view returns (uint256) {
        require(first[manager][tournament] != 0 && index < count[manager][tournament]);
        return first[manager][tournament] + index;
    }

    function createManagedMatch(
        address p0,
        address p1,
        uint256 c0,
        uint256 c1,
        uint256 tournament,
        uint256 seed,
        uint256 turn,
        uint256 index
    ) external returns (uint256) {
        uint256 id = managedMatchId(msg.sender, tournament, index);
        require(games[id].manager == address(0));
        games[id] = M(p0, p1, c0, c1, tournament, seed, turn, 0, false, msg.sender);
        return id;
    }

    function finish(uint256 id, uint256 result, bool defaulted) external {
        (games[id].result, games[id].defaulted) = (result, defaulted);
    }

    function matchInfo(uint256 id) external view returns (uint256[18] memory out) {
        M storage g = games[id];
        out[0] = uint256(uint160(g.p0));
        out[1] = uint256(uint160(g.p1));
        out[2] = g.c0;
        out[3] = g.c1;
        out[6] = g.result == 0 ? 3 : 4;
        out[9] = g.seed;
        out[14] = g.result;
        out[15] = g.tournament;
    }

    function managedInfo(uint256 id) external view returns (uint256[4] memory out) {
        out[0] = uint256(uint160(games[id].manager));
        out[1] = games[id].defaulted ? 1 : 0;
    }
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public skipMint;

    receive() external payable {
        deposit();
    }

    function setSkipMint(bool skip) external {
        skipMint = skip;
    }

    function deposit() public payable {
        if (!skipMint) balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
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
}

contract MockVault {
    MockWETH public immutable weth;
    mapping(address => uint256) public balanceOf;
    uint256 public numerator = 1;
    uint256 public denominator = 1;
    bool public failDeposit;
    bool public failPreview;
    bool public malformedPreview;
    bool public fakeTransfers;
    bool public quoteOverridden;
    uint256 public quoteOverride;
    uint256 public mintedShares;

    function setMintedShares(uint256 amount) external {
        mintedShares = amount;
    }
    ITournament public attackTarget;
    bool public attackSucceeded;
    uint256 public attackAttempts;

    function setFailDeposit(bool fail) external {
        failDeposit = fail;
    }

    constructor(MockWETH weth_) {
        weth = weth_;
    }

    function asset() external view returns (address) {
        return address(weth);
    }

    function setRate(uint256 n, uint256 d) external {
        (numerator, denominator) = (n, d);
    }

    function setFakeTransfers(bool fake) external {
        fakeTransfers = fake;
    }

    function setMalformedPreview(bool malformed) external {
        malformedPreview = malformed;
    }

    function setPreview(bool fail, bool overridden, uint256 quote) external {
        (failPreview, quoteOverridden, quoteOverride) = (fail, overridden, quote);
    }

    function setAttack(ITournament target) external {
        attackTarget = target;
    }

    function _attack() private {
        if (address(attackTarget) != address(0)) {
            ++attackAttempts;
            (bool ok,) =
                address(attackTarget).call(abi.encodeCall(ITournament.createTournament, (4, 0, 3600, 3600, 600, 3600)));
            attackSucceeded = attackSucceeded || ok;
        }
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        require(!failPreview, "preview disabled");
        if (malformedPreview) {
            assembly {
                mstore(0, 1)
                return(0, 1)
            }
        }
        return quoteOverridden ? quoteOverride : shares * numerator / denominator;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!failDeposit, "deposit disabled");
        _attack();
        weth.transferFrom(msg.sender, address(this), assets);
        shares = mintedShares == 0 ? assets : mintedShares;
        balanceOf[receiver] += shares;
    }

    function transfer(address to, uint256 shares) external returns (bool) {
        if (fakeTransfers) return true;
        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
        return true;
    }
}
