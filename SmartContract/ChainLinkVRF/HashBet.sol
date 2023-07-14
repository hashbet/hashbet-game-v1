// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./ChainSpecificUtil.sol";

interface IVRFCoordinatorV2 is VRFCoordinatorV2Interface {
    function getFeeConfig()
    external
    view
    returns (
      uint32 fulfillmentFlatFeeLinkPPMTier1,
      uint32 fulfillmentFlatFeeLinkPPMTier2,
      uint32 fulfillmentFlatFeeLinkPPMTier3,
      uint32 fulfillmentFlatFeeLinkPPMTier4,
      uint32 fulfillmentFlatFeeLinkPPMTier5,
      uint24 reqsForTier2,
      uint24 reqsForTier3,
      uint24 reqsForTier4,
      uint24 reqsForTier5
    );
}

contract HashBet is Ownable, ReentrancyGuard {
    // Modulo is the number of equiprobable outcomes in a game:
    //  2 for coin flip
    //  6 for dice roll
    //  6*6 = 36 for double dice
    //  37 for roulette
    //  100 for hashroll
    uint constant MAX_MODULO = 100;

    // Modulos below MAX_MASK_MODULO are checked against a bit mask, allowing betting on specific outcomes.
    // For example in a dice roll (modolo = 6),
    // 000001 mask means betting on 1. 000001 converted from binary to decimal becomes 1.
    // 101000 mask means betting on 4 and 6. 101000 converted from binary to decimal becomes 40.
    // The specific value is dictated by the fact that 256-bit intermediate
    // multiplication result allows implementing population count efficiently
    // for numbers that are up to 42 bits, and 40 is the highest multiple of
    // eight below 42.
    uint constant MAX_MASK_MODULO = 40;

    // EVM BLOCKHASH opcode can query no further than 256 blocks into the
    // past. Given that settleBet uses block hash of placeBet as one of
    // complementary entropy sources, we cannot process bets older than this
    // threshold. On rare occasions dice2.win croupier may fail to invoke
    // settleBet in this timespan due to technical issues or extreme Ethereum
    // congestion; such bets can be refunded via invoking refundBet.
    uint constant BET_EXPIRATION_BLOCKS = 250;

    // This is a check on bet mask overflow. Maximum mask is equivalent to number of possible binary outcomes for maximum modulo.
    uint constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    // These are constants taht make O(1) population count in placeBet possible.
    uint constant POPCNT_MULT =
        0x0000000000002000000000100000000008000000000400000000020000000001;
    uint constant POPCNT_MASK =
        0x0001041041041041041041041041041041041041041041041041041041041041;
    uint constant POPCNT_MODULO = 0x3F;

    // Sum of all historical deposits and withdrawals. Used for calculating profitability. Profit = Balance - cumulativeDeposit + cumulativeWithdrawal
    uint public cumulativeDeposit;
    uint public cumulativeWithdrawal;

    // In addition to house edge, wealth tax is added every time the bet amount exceeds a multiple of a threshold.
    // For example, if wealthTaxIncrementThreshold = 3000 ether,
    // A bet amount of 3000 ether will have a wealth tax of 1% in addition to house edge.
    // A bet amount of 6000 ether will have a wealth tax of 2% in addition to house edge.
    uint public wealthTaxIncrementThreshold = 3000 ether;
    uint public wealthTaxIncrementPercent = 1;

    // The minimum and maximum bets.
    uint public minBetAmount = 0.01 ether;
    uint public maxBetAmount = 10000 ether;

    // max bet profit. Used to cap bets against dynamic odds.
    uint public maxProfit = 300000 ether;

    // Funds that are locked in potentially winning bets. Prevents contract from committing to new bets that it cannot pay out.
    uint public lockedInBets;

    // The minimum larger comparison value.
    uint public minOverValue = 1;

    // The maximum smaller comparison value.
    uint public maxUnderValue = 98;

    uint256 public VRFFees;

    address public ChainLinkVRF;

    AggregatorV3Interface public LINK_ETH_FEED;
    IVRFCoordinatorV2 public IChainLinkVRF;
    bytes32 public ChainLinkKeyHash;
    uint64 public  ChainLinkSubID;


    // Info of each bet.
    struct Bet {
        // Wager amount in wei.
        uint amount;
        // Modulo of a game.
        uint8 modulo;
        // Number of winning outcomes, used to compute winning payment (* modulo/rollEdge),
        // and used instead of mask for games with modulo > MAX_MASK_MODULO.
        uint8 rollEdge;
        // Bit mask representing winning bet outcomes (see MAX_MASK_MODULO comment).
        uint40 mask;
        // Block number of placeBet tx.
        uint placeBlockNumber;
        // Address of a gambler, used to pay out winning bets.
        address payable gambler;
        // Status of bet settlement.
        bool isSettled;
        // Outcome of bet.
        uint outcome;
        // Win amount.
        uint winAmount;
        // Random number used to settle bet.
        uint randomNumber;
        // Comparison method.
        bool isLarger;
        // VRF request id
        uint256 requestID;
    }

    // Each bet is deducted dynamic
    uint public defaultHouseEdgePercent = 2;

    uint256 public requestCounter;
    mapping(uint256 => uint256) s_requestIDToRequestIndex;
    mapping(uint256 => Bet) public bets;

    mapping(uint32 => uint32) public houseEdgePercents;

    // Events
    event BetPlaced(
        address indexed gambler,
        uint amount,
        uint indexed betID,
        uint8 indexed modulo,
        uint8 rollEdge,
        uint40 mask,
        bool isLarger
    );
    event BetSettled(
        address indexed gambler,
        uint amount,
        uint indexed betID,
        uint8 indexed modulo,
        uint8 rollEdge,
        uint40 mask,
        uint outcome,
        uint winAmount
    );
    event BetRefunded(address indexed gambler, uint amount);
    
    error OnlyCoordinatorCanFulfill(address have, address want);
    error NotAwaitingVRF();
    error AwaitingVRF(uint256 requestID);
    error RefundFailed();
    error InvalidValue(uint256 required, uint256 sent);
    error TransferFailed();

    constructor(
        address _vrf,
        address link_eth_feed,
        bytes32 keyHash,
        uint64 subID
    ) {
        IChainLinkVRF = IVRFCoordinatorV2(_vrf);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _vrf;
        ChainLinkKeyHash = keyHash;
        ChainLinkSubID = subID;
        houseEdgePercents[2] = 1;
        houseEdgePercents[6] = 1;
        houseEdgePercents[36] = 1;
        houseEdgePercents[37] = 3;
        houseEdgePercents[100] = 5;
    }

    // Fallback payable function used to top up the bank roll.
    fallback() external payable {
        cumulativeDeposit += msg.value;
    }

    receive() external payable {
        cumulativeDeposit += msg.value;
    }

    // See ETH balance.
    function getBalance() external view returns (uint) {
        return address(this).balance;
    }

    // Set default house edge percent
    function setDefaultHouseEdgePercent(uint _houseEdgePercent) external onlyOwner {
        require(
            _houseEdgePercent >= 1 && _houseEdgePercent <= 100,
            "houseEdgePercent must be a sane number"
        );
        defaultHouseEdgePercent = _houseEdgePercent;
    }

    // Set modulo house edge percent
    function setModuloHouseEdgePercent(uint32 _houseEdgePercent, uint32 _modulo) external onlyOwner {
        require(
            _houseEdgePercent >= 1 && _houseEdgePercent <= 100,
            "houseEdgePercent must be a sane number"
        );
        houseEdgePercents[_modulo] = _houseEdgePercent;
    }

    // Set min bet amount. minBetAmount should be large enough such that its house edge fee can cover the Chainlink oracle fee.
    function setMinBetAmount(uint _minBetAmount) external onlyOwner {
        minBetAmount = _minBetAmount * 1 gwei;
    }

    // Set max bet amount.
    function setMaxBetAmount(uint _maxBetAmount) external onlyOwner {
        require(
            _maxBetAmount < 5000000 ether,
            "maxBetAmount must be a sane number"
        );
        maxBetAmount = _maxBetAmount;
    }

    // Set max bet reward. Setting this to zero effectively disables betting.
    function setMaxProfit(uint _maxProfit) external onlyOwner {
        require(_maxProfit < 50000000 ether, "maxProfit must be a sane number");
        maxProfit = _maxProfit;
    }

    // Set wealth tax percentage to be added to house edge percent. Setting this to zero effectively disables wealth tax.
    function setWealthTaxIncrementPercent(
        uint _wealthTaxIncrementPercent
    ) external onlyOwner {
        wealthTaxIncrementPercent = _wealthTaxIncrementPercent;
    }

    // Set threshold to trigger wealth tax.
    function setWealthTaxIncrementThreshold(
        uint _wealthTaxIncrementThreshold
    ) external onlyOwner {
        wealthTaxIncrementThreshold = _wealthTaxIncrementThreshold;
    }

    // Owner can withdraw funds not exceeding balance minus potential win prizes by open bets
    function withdrawFunds(
        address payable beneficiary,
        uint withdrawAmount
    ) external onlyOwner {
        require(
            withdrawAmount <= address(this).balance,
            "Withdrawal amount larger than balance."
        );
        require(
            withdrawAmount <= address(this).balance - lockedInBets,
            "Withdrawal amount larger than balance minus lockedInBets"
        );
        beneficiary.transfer(withdrawAmount);
        cumulativeWithdrawal += withdrawAmount;
    }

    function emitBetPlacedEvent(
        address gambler,
        uint amount,
        uint betID,
        uint8 modulo,
        uint8 rollEdge,
        uint40 mask,
        bool isLarger
    ) private {
        // Record bet in event logs
        emit BetPlaced(
            gambler,
            amount,
            betID,
            uint8(modulo),
            uint8(rollEdge),
            uint40(mask),
            isLarger
        );
    }

    // Place bet
    function placeBet(
        uint betAmount,
        uint betMask,
        uint modulo,
        bool isLarger
    ) external payable nonReentrant {
        address msgSender = _msgSender();

        uint amount = betAmount;

        checkVRFFee(betAmount, 1000000);

        validateArguments(
            amount,
            betMask,
            modulo,
            isLarger
        );

        uint rollEdge;
        uint mask;

        if (modulo <= MAX_MASK_MODULO) {
            // Small modulo games can specify exact bet outcomes via bit mask.
            // rollEdge is a number of 1 bits in this mask (population count).
            // This magic looking formula is an efficient way to compute population
            // count on EVM for numbers below 2**40.
            rollEdge = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
            mask = betMask;
        } else {
            // Larger modulos games specify the right edge of half-open interval of winning bet outcomes.
            require(
                betMask > 0 && betMask <= modulo,
                "High modulo range, betMask larger than modulo."
            );
            rollEdge = betMask;
        }

        // Winning amount.
        uint possibleWinAmount = getDiceWinAmount(
            amount,
            modulo,
            rollEdge,
            isLarger
        );

        // Check whether contract has enough funds to accept this bet.
        require(
            lockedInBets + possibleWinAmount <= address(this).balance,
            "Unable to accept bet due to insufficient funds"
        );

        uint256 requestID = _requestRandomWords(1);

        // Update lock funds.
        lockedInBets += possibleWinAmount;

        s_requestIDToRequestIndex[requestID] = requestCounter;
        bets[requestCounter] = Bet({
            amount:amount, 
            modulo:uint8(modulo),
            rollEdge:uint8(rollEdge),
            mask:uint40(mask),
            placeBlockNumber:ChainSpecificUtil.getBlockNumber(),
            gambler:payable(msgSender),
            isSettled:false,
            outcome : 0,
            winAmount : 0,
            randomNumber : 0,
            isLarger : isLarger,
            requestID:requestID
            });


        // Record bet in event logs
        emitBetPlacedEvent(
            msgSender,
            amount,
            requestCounter,
            uint8(modulo),
            uint8(rollEdge),
            uint40(mask),
            isLarger
        );

        requestCounter += 1;
    }

    // Get the expected win amount after house edge is subtracted.
    function getDiceWinAmount(
        uint amount,
        uint modulo,
        uint rollEdge,
        bool isLarger
    ) private view returns (uint winAmount) {
        require(
            0 < rollEdge && rollEdge <= modulo,
            "Win probability out of range."
        );
        uint houseEdge = (amount * (getModuloHouseEdgePercent(uint32(modulo)) + getWealthTax(amount))) /
            100;
        uint realRollEdge = rollEdge;
        if (modulo == MAX_MODULO && isLarger) {
            realRollEdge = MAX_MODULO - rollEdge - 1;
        }
        winAmount = ((amount - houseEdge) * modulo) / realRollEdge;

        uint maxWinAmount = amount + maxProfit;

        if (winAmount > maxWinAmount) {
            winAmount = maxWinAmount;
        }
    }

    // Get wealth tax
    function getWealthTax(uint amount) private view returns (uint wealthTax) {
        wealthTax =
            (amount / wealthTaxIncrementThreshold) *
            wealthTaxIncrementPercent;
    }

    // Common settlement code for settleBet.
    function settleBetCommon(
        Bet storage bet,
        uint reveal,
        bytes32 entropyBlockHash
    ) private {
        // Fetch bet parameters into local variables (to save gas).
        uint amount = bet.amount;

        // Validation check
        require(amount > 0, "Bet does not exist."); // Check that bet exists
        require(bet.isSettled == false, "Bet is settled already"); // Check that bet is not settled yet

        // Fetch bet parameters into local variables (to save gas).
        uint modulo = bet.modulo;
        uint rollEdge = bet.rollEdge;
        address payable gambler = bet.gambler;
        bool isLarger = bet.isLarger;

        // The RNG - combine "reveal" and blockhash of placeBet using Keccak256. Miners
        // are not aware of "reveal" and cannot deduce it from "commit" (as Keccak256
        // preimage is intractable), and house is unable to alter the "reveal" after
        // placeBet have been mined (as Keccak256 collision finding is also intractable).
        bytes32 entropy = keccak256(abi.encodePacked(reveal, entropyBlockHash));

        // Do a roll by taking a modulo of entropy. Compute winning amount.
        uint outcome = uint(entropy) % modulo;

        // Win amount if gambler wins this bet
        uint possibleWinAmount = getDiceWinAmount(
            amount,
            modulo,
            rollEdge,
            isLarger
        );

        // Actual win amount by gambler
        uint winAmount = 0;

        // Determine dice outcome.
        if (modulo <= MAX_MASK_MODULO) {
            // For small modulo games, check the outcome against a bit mask.
            if ((2 ** outcome) & bet.mask != 0) {
                winAmount = possibleWinAmount;
            }
        } else {
            // For larger modulos, check inclusion into half-open interval.
            if (isLarger) {
                if (outcome > rollEdge) {
                    winAmount = possibleWinAmount;
                }
            } else {
                if (outcome < rollEdge) {
                    winAmount = possibleWinAmount;
                }
            }
        }

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = winAmount;
        bet.randomNumber = reveal;
        bet.outcome = outcome;

        // Send win amount to gambler.
        if (bet.winAmount > 0) {
            gambler.transfer(bet.winAmount);
        }

        emitSettledEvent(bet);
    }

    function emitSettledEvent(Bet storage bet) private {
        uint amount = bet.amount;
        uint outcome = bet.outcome;
        uint winAmount = bet.winAmount;
        // Fetch bet parameters into local variables (to save gas).
        uint modulo = bet.modulo;
        uint rollEdge = bet.rollEdge;
        address payable gambler = bet.gambler;
        // Record bet settlement in event log.
        emit BetSettled(
            gambler,
            amount,
            s_requestIDToRequestIndex[bet.requestID],
            uint8(modulo),
            uint8(rollEdge),
            bet.mask,
            outcome,
            winAmount
        );
    }

    // Return the bet in extremely unlikely scenario it was not settled by Chainlink VRF.
    // In case you ever find yourself in a situation like this, just contact hashbet support.
    // However, nothing precludes you from calling this method yourself.
    function refundBet(uint256 betID) external payable nonReentrant {
        Bet storage bet = bets[betID];
        uint amount = bet.amount;
        bool isLarger = bet.isLarger;

        // Validation check
        require (amount > 0, "Bet does not exist."); // Check that bet exists
        require (bet.isSettled == false, "Bet is settled already."); // Check that bet is still open
        require(
            ChainSpecificUtil.getBlockNumber() > bet.placeBlockNumber + BET_EXPIRATION_BLOCKS,
            "Wait after placing bet before requesting refund."
        );

        uint possibleWinAmount = getDiceWinAmount(
            amount,
            bet.modulo,
            bet.rollEdge,
            isLarger
        );

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = amount;

        // Send the refund.
        bet.gambler.transfer(amount);

        // Record refund in event logs
        emit BetRefunded(bet.gambler, amount);

        delete (s_requestIDToRequestIndex[bet.requestID]);
    }

    /**
     * @dev calculates in form of native token the fee charged by chainlink VRF
     * @return fee amount of fee user has to pay
     */
    function getVRFFee(
        uint256 gasAmount
    ) public view returns (uint256 fee) {
        (, int256 answer, , , ) = LINK_ETH_FEED.latestRoundData();
        (uint32 fulfillmentFlatFeeLinkPPMTier1, , , , , , , , ) = IChainLinkVRF
            .getFeeConfig();

        uint256 l1Multiplier = ChainSpecificUtil.getL1Multiplier();
        uint256 l1CostWei = (ChainSpecificUtil.getCurrentTxL1GasFees() *
            l1Multiplier) / 10;
        fee =
            tx.gasprice *
            (gasAmount) +
            l1CostWei +
            ((1e12 *
                uint256(fulfillmentFlatFeeLinkPPMTier1) *
                uint256(answer)) / 1e18);
    }

    /**
     * @dev function to transfer VRF fees acumulated in the contract to the Bankroll
     * Can only be called by owner
     */
    function transferFees(address to) external nonReentrant {
        uint256 fee = VRFFees;
        VRFFees = 0;
        (bool success, ) = payable(address(to)).call{value: fee}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    // Check arguments
    function validateArguments(
        uint amount,
        uint betMask,
        uint modulo,
        bool isLarger
    ) private view {
        // Validate input data.
        require(
            modulo > 1 && modulo <= MAX_MODULO,
            "Modulo should be within range."
        );
        require(
            amount >= minBetAmount && amount <= maxBetAmount,
            "Bet amount should be within range."
        );
        require(
            betMask > 0 && betMask < MAX_BET_MASK,
            "Mask should be within range."
        );

        if (modulo > MAX_MASK_MODULO) {
            if (isLarger) {
                require(
                    betMask >= minOverValue && betMask <= modulo,
                    "High modulo range, betMask must larger than minimum larger comparison value."
                );
            } else {
                require(
                    betMask > 0 && betMask <= maxUnderValue,
                    "High modulo range, betMask must smaller than maximum smaller comparison value."
                );
            }
        }
    }

    /**
     * @dev function to send the request for randomness to chainlink
     * @param numWords number of random numbers required
     */
    function _requestRandomWords(
        uint32 numWords
    ) internal returns (uint256 s_requestID) {
        s_requestID = VRFCoordinatorV2Interface(ChainLinkVRF)
            .requestRandomWords(
                ChainLinkKeyHash,
                ChainLinkSubID,
                3,
                2500000,
                numWords
            );
    }

    /**
     * @dev function called by Chainlink VRF with random numbers
     * @param requestID id provided when the request was made
     * @param randomWords array of random numbers
     */
    function rawFulfillRandomWords(
        uint256 requestID,
        uint256[] memory randomWords
    ) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestID, randomWords);
    }

    function fulfillRandomWords(
        uint256 requestID,
        uint256[] memory randomWords
    ) internal {
        uint256 betID = s_requestIDToRequestIndex[requestID];
        Bet storage bet = bets[betID];
        if (bet.gambler == address(0)) revert();
        uint placeBlockNumber = bet.placeBlockNumber;

        // Check that bet has not expired yet (see comment to BET_EXPIRATION_BLOCKS).
        require(ChainSpecificUtil.getBlockNumber() > placeBlockNumber, "settleBet before placeBet");
        require (ChainSpecificUtil.getBlockNumber() <= placeBlockNumber + BET_EXPIRATION_BLOCKS, "Blockhash can't be queried by EVM.");

        // Settle bet using reveal and blockHash as entropy sources.
        settleBetCommon(bet, randomWords[0], ChainSpecificUtil.getBlockhash(placeBlockNumber));

        delete (s_requestIDToRequestIndex[requestID]);
    }

     /**
     * @dev returns to user the excess fee sent to pay for the VRF
     * @param refund amount to send back to user
     */
    function refundExcessValue(uint256 refund) internal {
        if (refund == 0) {
            return;
        }
        (bool success, ) = payable(msg.sender).call{value: refund}("");
        if (!success) {
            revert RefundFailed();
        }
    }

    function checkVRFFee(uint betAmount, uint256 gasAmount) internal {
        uint256 VRFfee = getVRFFee(gasAmount);

        if (msg.value < betAmount + VRFfee) {
            revert InvalidValue(betAmount + VRFfee, msg.value);
        }
        refundExcessValue(msg.value - (VRFfee + betAmount));

        VRFFees += VRFfee;
    }

    function getModuloHouseEdgePercent(uint32 modulo) internal view returns (uint32 houseEdgePercent)  {
        houseEdgePercent = houseEdgePercents[modulo];
        if(houseEdgePercent == 0){
            houseEdgePercent = uint32(defaultHouseEdgePercent);
        }
    }
}