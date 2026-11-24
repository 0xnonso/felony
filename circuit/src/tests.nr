use crate::commitment::{commitment_from_digest, commitment_hash, model_digest, NP, pack_weights};
use crate::network::{
    forward, L1_BIASES, L1_WEIGHTS, L2_BIASES, L2_WEIGHTS, L3_BIASES, L3_WEIGHTS, NB, NI, NW,
    requantize, shifted_accumulator, TICKET_MAX,
};
use crate::sampling::{assert_selected, draw, effective_tickets, low_64_bits, sample_hash};
use crate::state::{bid_feature, decode_state, features, GameState, score_feature, validate_state};
use crate::validate_context;

global ZERO_WEIGHT: u8 = 128;
global ZERO_BIAS: u32 = 2147483648;
global TWO_POW_40: Field = 1099511627776;

global CHAIN_ID: u64 = 31337;
global CONTRACT: Field = 0xc0ffee;
global MATCH_ID: Field = 77;
global PLAYER: u8 = 1;
global SEED: Field = 0x1234567890abcdef;
global KEY: Field = 0xabc123;
global SALT: Field = 99;

global ORDER: [u8; 9] = [5, 1, 9, 3, 7, 2, 8, 4, 6];
global OWN_PLAY: [u8; 9] = [5, 2, 9, 1, 7, 3, 8, 4, 6];
global OPP_PLAY: [u8; 9] = [6, 1, 9, 2, 3, 7, 4, 8, 5];

struct RawState {
    own: [bool; 9],
    opp: [bool; 9],
    loot: [bool; 9],
    current: u8,
    score: u8,
    own_bids: [u8; 9],
    opp_bids: [u8; 9],
}

fn pow2(n: u32) -> Field {
    let mut value: Field = 1;
    for _ in 0..n {
        value *= 2;
    }
    value
}

fn mask_value(mask: [bool; 9]) -> Field {
    let mut value: Field = 0;
    for i in 0..9 {
        value += (mask[i] as Field) * pow2(i);
    }
    value
}

fn encode(s: RawState) -> Field {
    let mut value = mask_value(s.own)
        + mask_value(s.opp) * pow2(9)
        + mask_value(s.loot) * pow2(18)
        + (s.current as Field) * pow2(27)
        + (s.score as Field) * pow2(31);
    for i in 0..9 {
        value += (s.own_bids[i] as Field) * pow2(38 + 4 * i);
        value += (s.opp_bids[i] as Field) * pow2(74 + 4 * i);
    }
    value
}

fn after_rounds(rounds: u32) -> RawState {
    let mut s = RawState {
        own: [true; 9],
        opp: [true; 9],
        loot: [true; 9],
        current: ORDER[rounds],
        score: 45,
        own_bids: [0; 9],
        opp_bids: [0; 9],
    };
    for r in 0..rounds {
        let value = ORDER[r];
        let index = (value - 1) as u32;
        let own = OWN_PLAY[r];
        let opp = OPP_PLAY[r];
        s.own[(own - 1) as u32] = false;
        s.opp[(opp - 1) as u32] = false;
        s.loot[index] = false;
        s.own_bids[index] = own;
        s.opp_bids[index] = opp;
        if own > opp {
            s.score += value;
        } else if own < opp {
            s.score -= value;
        }
    }
    s
}

fn check(s: RawState, round: u8) -> GameState {
    let game = decode_state(encode(s));
    validate_state(game, round);
    game
}

#[test]
fn every_round_of_the_scripted_game_is_valid() {
    for r in 0..9 {
        let _ = check(after_rounds(r), r as u8);
    }
}

#[test]
fn decode_reads_each_field() {
    let game = check(after_rounds(3), 3);
    assert(game.current == 3);
    assert(game.score == 41);
    assert(game.own_bids == [2, 0, 0, 0, 5, 0, 0, 0, 9]);
    assert(game.opp_bids == [1, 0, 0, 0, 6, 0, 0, 0, 9]);
    assert(game.own_hand == [true, false, true, true, false, true, true, true, false]);
    assert(game.opp_hand == [false, true, true, true, true, false, true, true, false]);
    assert(game.loot == [false, true, true, true, false, true, true, true, false]);
}

#[test(should_fail_with = "Field failed to decompose")]
fn bit_110_is_rejected() {
    let _ = decode_state(encode(after_rounds(3)) + pow2(110));
}

#[test(should_fail_with = "round out of range")]
fn state_round_nine_is_rejected() {
    let _ = check(after_rounds(3), 9);
}

#[test(should_fail_with = "own hand size does not match round")]
fn wrong_round_is_rejected() {
    let _ = check(after_rounds(3), 4);
}

#[test(should_fail_with = "opponent hand size does not match round")]
fn extra_opponent_card_is_rejected() {
    let mut s = after_rounds(3);
    s.opp[0] = true;
    let _ = check(s, 3);
}

#[test(should_fail_with = "loot count does not match round")]
fn extra_loot_is_rejected() {
    let mut s = after_rounds(3);
    s.loot[0] = true;
    let _ = check(s, 3);
}

#[test(should_fail_with = "current loot out of range")]
fn current_loot_zero_is_rejected() {
    let mut s = after_rounds(3);
    s.current = 0;
    let _ = check(s, 3);
}

#[test(should_fail_with = "current loot out of range")]
fn current_loot_ten_is_rejected() {
    let mut s = after_rounds(3);
    s.current = 10;
    let _ = check(s, 3);
}

#[test(should_fail_with = "current loot is not remaining")]
fn resolved_current_loot_is_rejected() {
    let mut s = after_rounds(3);
    s.current = 5;
    let _ = check(s, 3);
}

#[test(should_fail_with = "remaining loot has a recorded bid")]
fn bid_on_remaining_loot_is_rejected() {
    let mut s = after_rounds(3);
    s.own_bids[1] = 3;
    let _ = check(s, 3);
}

#[test(should_fail_with = "resolved loot has an invalid bid")]
fn missing_bid_on_resolved_loot_is_rejected() {
    let mut s = after_rounds(3);
    s.opp_bids[0] = 0;
    let _ = check(s, 3);
}

#[test(should_fail_with = "resolved loot has an invalid bid")]
fn bid_ten_is_rejected() {
    let mut s = after_rounds(3);
    s.own_bids[0] = 10;
    let _ = check(s, 3);
}

#[test(should_fail_with = "own bids do not match own hand")]
fn duplicate_own_bid_is_rejected() {
    let mut s = after_rounds(3);
    s.own_bids[0] = 5;
    let _ = check(s, 3);
}

#[test(should_fail_with = "opponent bids do not match opponent hand")]
fn bid_of_a_card_still_held_is_rejected() {
    let mut s = after_rounds(3);
    s.opp_bids[0] = 2;
    let _ = check(s, 3);
}

#[test(should_fail_with = "score does not match history")]
fn wrong_score_is_rejected() {
    let mut s = after_rounds(3);
    s.score = 42;
    let _ = check(s, 3);
}

#[test(should_fail_with = "score does not match history")]
fn score_above_range_is_rejected() {
    let mut s = after_rounds(3);
    s.score = 127;
    let _ = check(s, 3);
}

#[test]
fn score_feature_rounds_to_nearest_with_sign() {
    assert(score_feature(45) == 0);
    assert(score_feature(46) == 6);
    assert(score_feature(44) == 0 - 6);
    assert(score_feature(41) == 0 - 23);
    assert(score_feature(90) == 255);
    assert(score_feature(0) == 0 - 255);
}

#[test]
fn bid_feature_rounds_to_nearest() {
    assert(bid_feature(0) == 0);
    assert(bid_feature(1) == 28);
    assert(bid_feature(2) == 57);
    assert(bid_feature(5) == 142);
    assert(bid_feature(6) == 170);
    assert(bid_feature(9) == 255);
}

#[test]
fn features_follow_the_specified_order() {
    let x = features(check(after_rounds(3), 3));
    let expected: [Field; NI] = [
        255, 0, 255, 255, 0, 255, 255, 255, 0, 0, 255, 255, 255, 255, 0, 255, 255, 0, 0, 255, 255,
        255, 0, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0 - 23, 57, 0, 0, 0, 142, 0, 0, 0,
        255, 28, 0, 0, 0, 170, 0, 0, 0, 255,
    ];
    assert(x == expected);
}

#[test]
fn requantize_handles_rounding_sign_and_clipping() {
    assert(requantize(0 - 1, 255) == 0);
    assert(requantize(0 - 1000000, 255) == 0);
    assert(requantize(0, 255) == 0);
    assert(requantize(127, 255) == 0);
    assert(requantize(128, 255) == 1);
    assert(requantize(383, 255) == 1);
    assert(requantize(384, 255) == 2);
    assert(requantize(65279, 255) == 255);
    assert(requantize(65408, 255) == 255);
    assert(requantize(16777087, TICKET_MAX) == 65535);
    assert(requantize(2147483647, TICKET_MAX) == 65535);
}

#[test]
fn accumulator_limits_are_accepted() {
    assert(shifted_accumulator(0 - TWO_POW_40) == 0);
    assert(shifted_accumulator(TWO_POW_40 - 1) == 2199023255551);
}

#[test(should_fail_with = "call to assert_max_bit_size")]
fn accumulator_above_limit_is_rejected() {
    let _ = shifted_accumulator(TWO_POW_40);
}

#[test(should_fail_with = "call to assert_max_bit_size")]
fn accumulator_below_limit_is_rejected() {
    let _ = shifted_accumulator(0 - TWO_POW_40 - 1);
}

fn blank_model() -> ([u8; NW], [u32; NB]) {
    ([ZERO_WEIGHT; NW], [ZERO_BIAS; NB])
}

#[test]
fn hand_computed_network_path() {
    let (mut w, mut b) = blank_model();

    w[L1_WEIGHTS + 0 * NI + 0] = 129;

    b[L2_BIASES + 0] = ZERO_BIAS + 1000;
    w[L2_WEIGHTS + 0 * 128 + 0] = 255;

    b[L3_BIASES + 2] = ZERO_BIAS - 144;
    w[L3_WEIGHTS + 2 * 128 + 0] = 228;

    b[L3_BIASES + 3] = 4294967295;
    w[L3_WEIGHTS + 3 * 128 + 0] = 0;

    b[L3_BIASES + 4] = 0;

    b[L1_BIASES + 1] = ZERO_BIAS - 1;

    let mut x = [0; NI];
    x[0] = 255;
    let t = forward(x, w, b);
    assert(t.acc1[0] == 255);
    assert(t.hidden1[0] == 1);
    assert(t.acc1[1] == 0 - 1);
    assert(t.hidden1[1] == 0);
    assert(t.acc2[0] == 1127);
    assert(t.hidden2[0] == 4);
    assert(t.acc3[2] == 256);
    assert(t.acc3[3] == 2147483647 - 512);
    assert(t.tickets == [0, 0, 1, 65535, 0, 0, 0, 0, 0]);
}

#[test]
fn negative_score_feature_reaches_the_network() {
    let (mut w, mut b) = blank_model();
    w[L1_WEIGHTS + 36] = 0;
    b[L1_BIASES] = ZERO_BIAS;
    let mut x = [0; NI];
    x[36] = 0 - 255;
    let t = forward(x, w, b);
    assert(t.acc1[0] == 32640);
    assert(t.hidden1[0] == 128);
}

#[test]
fn packing_is_little_endian_with_high_padding() {
    let mut w = [0 as u8; NW];
    w[0] = 1;
    w[1] = 2;
    w[30] = 3;
    w[31] = 4;
    w[NW - 1] = 7;
    let packed = pack_weights(w);
    assert(NP == 793);
    let mut top: Field = 3;
    let mut last: Field = 7;
    for i in 0..30 {
        top *= 256;
        if i < 23 {
            last *= 256;
        }
    }
    assert(packed[0] == 1 + 2 * 256 + top);
    assert(packed[1] == 4);
    assert(packed[792] == last);
}

#[test]
fn commitment_binds_every_private_value() {
    let (w, b) = test_model();
    let base = commitment_hash(w, b, KEY, SALT);
    let mut w2 = w;
    w2[NW - 1] = w2[NW - 1] ^ 1;
    let mut b2 = b;
    b2[NB - 1] = b2[NB - 1] ^ 1;
    assert(base != commitment_hash(w2, b, KEY, SALT));
    assert(base != commitment_hash(w, b2, KEY, SALT));
    assert(base != commitment_hash(w, b, KEY + 1, SALT));
    assert(base != commitment_hash(w, b, KEY, SALT + 1));
    assert(base == commitment_from_digest(model_digest(w, b), KEY, SALT));
    assert(commitment_from_digest(1, 2, 3) != commitment_from_digest(1, 3, 2));
}

#[test]
fn low_bits_use_the_canonical_representative() {
    assert(low_64_bits(0) == 0);
    assert(low_64_bits(5) == 5);
    assert(low_64_bits(pow2(64) + 9) == 9);
    assert(low_64_bits(pow2(64) - 1) == 18446744073709551615);
    assert(low_64_bits(0 - 1) == 0x43e1f593f0000000);
}

#[test]
fn draw_is_the_remainder_of_the_low_bits() {
    assert(draw(pow2(64) + 17, 5) == 2);
    assert(draw(0 - 1, 1) == 0);
}

#[test(should_fail_with = "ticket total is zero")]
fn zero_total_is_rejected() {
    let _ = draw(1, 0);
}

#[test]
fn sample_hash_binds_every_context_field() {
    let base = sample_hash(KEY, CHAIN_ID, CONTRACT, MATCH_ID, PLAYER, 3, SEED);
    assert(base != sample_hash(KEY + 1, CHAIN_ID, CONTRACT, MATCH_ID, PLAYER, 3, SEED));
    assert(base != sample_hash(KEY, CHAIN_ID + 1, CONTRACT, MATCH_ID, PLAYER, 3, SEED));
    assert(base != sample_hash(KEY, CHAIN_ID, CONTRACT + 1, MATCH_ID, PLAYER, 3, SEED));
    assert(base != sample_hash(KEY, CHAIN_ID, CONTRACT, MATCH_ID + 1, PLAYER, 3, SEED));
    assert(base != sample_hash(KEY, CHAIN_ID, CONTRACT, MATCH_ID, 0, 3, SEED));
    assert(base != sample_hash(KEY, CHAIN_ID, CONTRACT, MATCH_ID, PLAYER, 4, SEED));
    assert(base != sample_hash(KEY, CHAIN_ID, CONTRACT, MATCH_ID, PLAYER, 3, SEED + 1));
}

global SOME_HAND: [bool; 9] = [false, true, false, true, true, false, false, false, true];

#[test]
fn unavailable_cards_lose_their_tickets() {
    let (t, total) = effective_tickets([9, 3, 9, 0, 2, 9, 9, 9, 65535], SOME_HAND);
    assert(t == [0, 3, 0, 0, 2, 0, 0, 0, 65535]);
    assert(total == 65540);
}

#[test]
fn all_zero_falls_back_to_lowest_card_in_hand() {
    let (t, total) = effective_tickets([9, 0, 9, 0, 0, 9, 9, 9, 0], SOME_HAND);
    assert(t == [0, 1, 0, 0, 0, 0, 0, 0, 0]);
    assert(total == 1);
}

#[test]
fn saturated_tickets_reach_the_maximum_total() {
    let (_, total) = effective_tickets([65535; 9], [true; 9]);
    assert(total == 589815);
}

global SPLIT: [u32; 9] = [3, 0, 2, 0, 0, 0, 0, 0, 1];

#[test]
fn each_draw_selects_its_interval() {
    assert_selected(SPLIT, 0, 0);
    assert_selected(SPLIT, 2, 0);
    assert_selected(SPLIT, 3, 2);
    assert_selected(SPLIT, 4, 2);
    assert_selected(SPLIT, 5, 8);
}

#[test(should_fail_with = "action is not the sampled card")]
fn zero_ticket_card_is_not_selectable() {
    assert_selected(SPLIT, 3, 1);
}

#[test(should_fail_with = "action is not the sampled card")]
fn earlier_card_is_rejected() {
    assert_selected(SPLIT, 3, 0);
}

#[test(should_fail_with = "action is not the sampled card")]
fn later_card_is_rejected() {
    assert_selected(SPLIT, 2, 2);
}

#[test(should_fail_with = "action is not the sampled card")]
fn draw_past_the_total_is_rejected() {
    assert_selected(SPLIT, 6, 8);
}

#[test]
fn valid_context_is_accepted() {
    validate_context(KEY, pow2(160) - 1, 1, 8, 8);
}

#[test(should_fail_with = "sampling key is zero")]
fn zero_key_is_rejected() {
    validate_context(0, CONTRACT, 0, 0, 0);
}

#[test(should_fail_with = "call to assert_max_bit_size")]
fn oversized_address_is_rejected() {
    validate_context(KEY, pow2(160), 0, 0, 0);
}

#[test(should_fail_with = "player id out of range")]
fn player_two_is_rejected() {
    validate_context(KEY, CONTRACT, 2, 0, 0);
}

#[test(should_fail_with = "round out of range")]
fn round_nine_is_rejected() {
    validate_context(KEY, CONTRACT, 0, 9, 0);
}

#[test(should_fail_with = "action out of range")]
fn action_nine_is_rejected() {
    validate_context(KEY, CONTRACT, 0, 0, 9);
}

fn test_model() -> ([u8; NW], [u32; NB]) {
    let mut w = [0 as u8; NW];
    let mut s: u64 = 12345;
    for i in 0..NW {
        s = (s * 1103515245 + 12345) % 4294967296;
        w[i] = ((s >> 16) % 256) as u8;
    }
    let mut b = [0 as u32; NB];
    for i in 0..NB {
        s = (s * 1103515245 + 12345) % 4294967296;
        b[i] = (2147483648 - 20000 + (s >> 16) % 40000) as u32;
    }
    (w, b)
}

fn prove(
    w: [u8; NW],
    b: [u32; NB],
    key: Field,
    salt: Field,
    commitment: Field,
    state: Field,
    round: u8,
    action: u8,
) {
    crate::main(
        w,
        b,
        key,
        salt,
        commitment,
        state,
        CHAIN_ID,
        CONTRACT,
        MATCH_ID,
        PLAYER,
        round,
        SEED,
        action,
    );
}

struct Honest {
    w: [u8; NW],
    b: [u32; NB],
    commitment: Field,
    state: Field,
    action: u8,
}

fn honest_case() -> Honest {
    let (w, b) = test_model();
    let state = encode(after_rounds(3));
    Honest {
        w,
        b,
        // Fixed outputs from the independent Python integer reference.
        commitment: 5155143889745337063159054419138836141945132892555386498366392856623798722139,
        state,
        action: 5,
    }
}

#[test]
fn honest_action_is_accepted() {
    let c = honest_case();
    assert(c.state == 730174173401210728134316538838253);
    prove(c.w, c.b, KEY, SALT, c.commitment, c.state, 3, c.action);
}

#[test]
fn forced_last_card_is_accepted() {
    let (w, b) = test_model();
    let state = encode(after_rounds(8));
    // The scripted game leaves only card 6; its action index is 5.
    let action: u8 = 5;
    prove(
        w,
        b,
        KEY,
        SALT,
        commitment_hash(w, b, KEY, SALT),
        state,
        8,
        action,
    );
}

#[test]
fn all_zero_model_plays_lowest_card_in_hand() {
    let w = [ZERO_WEIGHT; NW];
    let b = [0 as u32; NB];
    let state = encode(after_rounds(3));
    prove(
        w,
        b,
        KEY,
        SALT,
        commitment_hash(w, b, KEY, SALT),
        state,
        3,
        0,
    );
}

#[test(should_fail_with = "action is not the sampled card")]
fn legal_unselected_card_is_rejected() {
    let c = honest_case();

    let other: u8 = if c.action == 0 { 2 } else { 0 };
    prove(c.w, c.b, KEY, SALT, c.commitment, c.state, 3, other);
}

#[test(should_fail_with = "action is not the sampled card")]
fn played_card_is_rejected() {
    let c = honest_case();
    prove(c.w, c.b, KEY, SALT, c.commitment, c.state, 3, 4);
}

#[test(should_fail_with = "commitment mismatch")]
fn changed_weight_is_rejected() {
    let c = honest_case();
    let mut w = c.w;
    w[5000] = w[5000] ^ 1;
    prove(w, c.b, KEY, SALT, c.commitment, c.state, 3, c.action);
}

#[test(should_fail_with = "commitment mismatch")]
fn changed_bias_is_rejected() {
    let c = honest_case();
    let mut b = c.b;
    b[100] = b[100] ^ 1;
    prove(c.w, b, KEY, SALT, c.commitment, c.state, 3, c.action);
}

#[test(should_fail_with = "commitment mismatch")]
fn changed_key_is_rejected() {
    let c = honest_case();
    prove(c.w, c.b, KEY + 1, SALT, c.commitment, c.state, 3, c.action);
}

#[test(should_fail_with = "commitment mismatch")]
fn changed_salt_is_rejected() {
    let c = honest_case();
    prove(c.w, c.b, KEY, SALT + 1, c.commitment, c.state, 3, c.action);
}

#[test(should_fail_with = "own hand size does not match round")]
fn state_from_another_round_is_rejected() {
    let c = honest_case();
    prove(c.w, c.b, KEY, SALT, c.commitment, c.state, 4, c.action);
}

global VECTOR_STATE: Field = 326796363340167800439493877524285;
global VECTOR_CHAIN: u64 = 31337;
global VECTOR_CONTRACT: Field = 81985529216486895;
global VECTOR_ROUND: u8 = 3;

struct Vector {
    key: Field,
    salt: Field,
    match_id: Field,
    player: u8,
    seed: Field,
    digest: Field,
    commitment: Field,
    hash: Field,
    low_bits: u64,
    r: u32,
    total: u32,
    action: u8,
}

fn check_vector(w: [u8; NW], b: [u32; NB], v: Vector) {
    assert(model_digest(w, b) == v.digest);
    assert(commitment_hash(w, b, v.key, v.salt) == v.commitment);
    let hash = sample_hash(
        v.key,
        VECTOR_CHAIN,
        VECTOR_CONTRACT,
        v.match_id,
        v.player,
        VECTOR_ROUND,
        v.seed,
    );
    assert(hash == v.hash);
    assert(low_64_bits(hash) == v.low_bits);
    assert(draw(hash, v.total) == v.r);
    let game = decode_state(VECTOR_STATE);
    let (_, total) = effective_tickets(forward(features(game), w, b).tickets, game.own_hand);
    assert(total == v.total);
    crate::main(
        w,
        b,
        v.key,
        v.salt,
        v.commitment,
        VECTOR_STATE,
        VECTOR_CHAIN,
        VECTOR_CONTRACT,
        v.match_id,
        v.player,
        VECTOR_ROUND,
        v.seed,
        v.action,
    );
}

#[test]
fn python_vector_zero_model() {
    check_vector(
        [128; NW],
        [2147483648; NB],
        Vector {
            key: 256731055702445221778,
            salt: 11259384,
            match_id: 109,
            player: 1,
            seed: 3571081214781330,
            digest: 14255605624438057049068573203948612156194464875403634711075922258336180108985,
            commitment: 6116218438382580284414374401548639311303174935440836997290465071020778131745,
            hash: 19252540663821721308747759843358766306136962745657998493384141756284338668012,
            low_bits: 13686066090936861164,
            r: 0,
            total: 1,
            action: 0,
        },
    );
}

#[test]
fn python_vector_maximum_model() {
    check_vector(
        [255; NW],
        [4294967295; NB],
        Vector {
            key: 256731055702445221779,
            salt: 11259385,
            match_id: 110,
            player: 0,
            seed: 3571081214781331,
            digest: 8305312224898541081858598577685884638635773111512679695611614643580389643780,
            commitment: 995198046813391641243649425549676743639870841679524831087514496031514118819,
            hash: 7950843318535325566468880677021150324325117897926967185080149229533812514377,
            low_bits: 693598534351740489,
            r: 377049,
            total: 393210,
            action: 8,
        },
    );
}

#[test]
fn python_vector_minimum_model() {
    check_vector(
        [0; NW],
        [0; NB],
        Vector {
            key: 256731055702445221780,
            salt: 11259386,
            match_id: 111,
            player: 1,
            seed: 3571081214781332,
            digest: 11134458006061960720863293079363234922975300426430601359652675065977217714177,
            commitment: 21015407549886308713920924450550584562284730421446732358317142362319849645399,
            hash: 1287578081589170123952518340879393092188745355305567812265766863254778528833,
            low_bits: 8959790754459534401,
            r: 0,
            total: 1,
            action: 0,
        },
    );
}
