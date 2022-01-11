// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/Address.sol";
import "./libraries/SafeMath.sol";

import "./types/ERC20Permit.sol";

import "./interfaces/IsSWIX.sol";
import "./interfaces/IStaking.sol";

contract SSwixToken is IsSWIX, ERC20Permit {
    using SafeMath for uint256;

    /* =====================================================
                            STRUCTS
     ===================================================== */

    struct Rebase {
        uint256 epoch;
        uint256 rebase; // 18 decimals
        uint256 totalStakedBefore;
        uint256 totalStakedAfter;
        uint256 amountRebased;
        uint256 index;
        uint256 blockNumberOccured;
    }

    /* =====================================================
                            CONSTANTS
     ===================================================== */

    uint256 private constant MAX_UINT256 = type(uint256).max;
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5_000_000 * 10**9;

    // TOTAL_GONS is a multiple of INITIAL_FRAGMENTS_SUPPLY so that _gonsPerFragment is an integer.
    // Use the highest value that fits in a uint256 for max granularity.
    uint256 private constant TOTAL_GONS =
        MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

    // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
    uint256 private constant MAX_SUPPLY = ~uint128(0); // (2^128) - 1


    /* =====================================================
                    PUBLIC STATE VARIABLES
     ===================================================== */

    // balance used to calc rebase
    address public stakingContract;

    /// Past rebase data
    Rebase[] public rebases;


    /* =====================================================
                    INTERNAL STATE VARIABLES
     ===================================================== */

    address internal initializer;

    // Index Gons - tracks rebase growth
    uint256 internal sSwixIndex;


    /* =====================================================
                    PRIVATE STATE VARIABLES
     ===================================================== */

    uint256 private _gonsPerFragment;
    mapping(address => uint256) private _gonBalances;

    mapping(address => mapping(address => uint256)) private _allowedValue;

    address public treasury;
   

    /* =====================================================
                            MODIFIERS
     ===================================================== */

    modifier onlyStakingContract() {
        require(
            msg.sender == stakingContract,
            "StakingContract:  call is not staking contract"
        );
        _;
    }


    /* =====================================================
                            CONSTRUCTOR
     ===================================================== */

    constructor()
        ERC20("Staked SWIX", "sSWIX", 18)
        ERC20Permit("Staked SWIX")
    {
        initializer = msg.sender;
        _totalSupply = INITIAL_FRAGMENTS_SUPPLY;
        _gonsPerFragment = TOTAL_GONS.div(_totalSupply);
    }


    /* =====================================================
                        INITIALIZATION
     ===================================================== */

    function setIndex(uint256 newIndex)
        external
    {
        require(
            msg.sender == initializer,
            "Initializer:  caller is not initializer"
        );
        require(sSwixIndex == 0, "Cannot set INDEX again");
        sSwixIndex = gonsForBalance(newIndex);
    }

    // do this last
    function initialize(address setStakingContract, address settreasury)
        external
    {
        require(
            msg.sender == initializer,
            "Initializer:  caller is not initializer"
        );
        require(settreasury != address(0), "Zero address: Treasury");
        require(setStakingContract != address(0), "Staking");
        
        stakingContract = setStakingContract;
        _gonBalances[stakingContract] = TOTAL_GONS;

        treasury = settreasury;

        emit Transfer(address(0x0), stakingContract, _totalSupply);
        emit LogStakingContractUpdated(stakingContract);

        initializer = address(0);
    }


    /* =====================================================
                            REBASE
     ===================================================== */

    /// Increases rSWIX supply to increase staking balances relative to profit
    ///
    /// @param profit uint256
    ///
    /// @return uint256
    function rebase(uint256 profit, uint256 currentEpoch)
        public
        override
        onlyStakingContract
        returns (uint256)
    {
        uint256 rebaseAmount;
        uint256 circulatingSupply_ = circulatingSupply();

        if (profit == 0) {
            emit LogSupply(currentEpoch, _totalSupply);
            emit LogRebase(currentEpoch, 0, index());
            return _totalSupply;
        } else if (circulatingSupply_ > 0) {
            rebaseAmount = profit.mul(_totalSupply).div(circulatingSupply_);
        } else {
            rebaseAmount = profit;
        }

        _totalSupply = _totalSupply.add(rebaseAmount);

        if (_totalSupply > MAX_SUPPLY) {
            _totalSupply = MAX_SUPPLY;
        }

        _gonsPerFragment = TOTAL_GONS.div(_totalSupply);

        _storeRebase(circulatingSupply_, profit, currentEpoch);

        return _totalSupply;
    }

    /// Emits event with data about rebase
    ///
    /// @param previousCirculating uint
    /// @param profit uint
    /// @param currentEpoch uint
    function _storeRebase(
        uint256 previousCirculating,
        uint256 profit,
        uint256 currentEpoch
    )
        internal
    {
        uint256 rebasePercent = profit.mul(1e18).div(previousCirculating);
        rebases.push(
            Rebase({
                epoch: currentEpoch,
                rebase: rebasePercent, // 18 decimals
                totalStakedBefore: previousCirculating,
                totalStakedAfter: circulatingSupply(),
                amountRebased: profit,
                index: index(),
                blockNumberOccured: block.number
            })
        );

        emit LogSupply(currentEpoch, _totalSupply);
        emit LogRebase(currentEpoch, rebasePercent, index());
    }


    /* =====================================================
                        USER FUNCTIONS
     ===================================================== */

    function transfer(address to, uint256 value)
        public
        override(IERC20, ERC20)
        returns (bool)
    {
        uint256 gonValue = value.mul(_gonsPerFragment);

        _gonBalances[msg.sender] = _gonBalances[msg.sender].sub(gonValue);
        _gonBalances[to] = _gonBalances[to].add(gonValue);

        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    )
        public
        override(IERC20, ERC20)
        returns (bool)
    {
        _allowedValue[from][msg.sender] = _allowedValue[from][msg.sender].sub(
            value
        );
        emit Approval(from, msg.sender, _allowedValue[from][msg.sender]);

        uint256 gonValue = gonsForBalance(value);
        _gonBalances[from] = _gonBalances[from].sub(gonValue);
        _gonBalances[to] = _gonBalances[to].add(gonValue);

        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value)
        public
        override(IERC20, ERC20)
        returns (bool)
    {
        _approve(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        public
        override
        returns (bool)
    {
        _approve(
            msg.sender,
            spender,
            _allowedValue[msg.sender][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        override
        returns (bool)
    {
        uint256 oldValue = _allowedValue[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _approve(msg.sender, spender, 0);
        } else {
            _approve(msg.sender, spender, oldValue.sub(subtractedValue));
        }
        return true;
    }


    /* =====================================================
                        VIEW FUNCTIONS
     ===================================================== */

    function balanceOf(address who)
        public
        view
        override(IERC20, ERC20)
        returns (uint256)
    {
        return _gonBalances[who].div(_gonsPerFragment);
    }

    function gonsForBalance(uint256 amount)
        public
        view
        override
        returns (uint256)
    {
        return amount.mul(_gonsPerFragment);
    }

    function balanceForGons(uint256 gons)
        public
        view
        override
        returns (uint256)
    {
        return gons.div(_gonsPerFragment);
    }

    // Staking contract holds excess sSWIX
    function circulatingSupply()
        public
        view
        override
        returns (uint256)
    {
        return
            _totalSupply
                .sub(balanceOf(stakingContract))
                .add(IStaking(stakingContract).supplyInWarmup());
    }

    function index()
        public
        view
        override
        returns (uint256)
    {
        return balanceForGons(sSwixIndex);
    }

    function allowance(address owner_, address spender)
        public
        view
        override(IERC20, ERC20)
        returns (uint256)
    {
        return _allowedValue[owner_][spender];
    }

    
    /* =====================================================
                        INTERNAL FUNCTIONS
     ===================================================== */

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) internal virtual override {
        _allowedValue[owner][spender] = value;
        emit Approval(owner, spender, value);
    }


    /* =====================================================
                                EVENTS
    ===================================================== */

    event LogSupply(uint256 indexed epoch, uint256 totalSupply);
    event LogRebase(uint256 indexed epoch, uint256 rebase, uint256 index);
    event LogStakingContractUpdated(address stakingContract);
}
