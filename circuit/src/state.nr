pub global CARDS: u32 = 9;
pub global NUM_FEATURES: u32 = 55;
pub global STATE_BITS: u32 = 110;

global OWN_HAND_OFFSET: u32 = 0;
global OPP_HAND_OFFSET: u32 = 9;
global LOOT_OFFSET: u32 = 18;
global CURRENT_OFFSET: u32 = 27;
global SCORE_OFFSET: u32 = 31;
global OWN_BIDS_OFFSET: u32 = 38;
global OPP_BIDS_OFFSET: u32 = 74;

global SCORE_ZERO: u8 = 45;
global ON: Field = 255;

pub struct GameState {
    pub own_hand: [bool; CARDS],
    pub opp_hand: [bool; CARDS],
    pub loot: [bool; CARDS],
    pub current: u8,
    pub score: u8,
    pub own_bids: [u8; CARDS],
    pub opp_bids: [u8; CARDS],
}

fn read_mask(bits: [bool; STATE_BITS], offset: u32) -> [bool; CARDS] {
    let mut mask = [false; CARDS];
    for i in 0..CARDS {
        mask[i] = bits[offset + i];
    }
    mask
}

fn read_uint(bits: [bool; STATE_BITS], offset: u32, width: u32) -> u8 {
    let mut value: u8 = 0;
    let mut place: u8 = 1;
    for i in 0..width {
        value += (bits[offset + i] as u8) * place;
        place *= 2;
    }
    value
}

fn read_bids(bits: [bool; STATE_BITS], offset: u32) -> [u8; CARDS] {
    let mut bids = [0; CARDS];
    for i in 0..CARDS {
        bids[i] = read_uint(bits, offset + 4 * i, 4);
    }
    bids
}

pub fn decode_state(state: Field) -> GameState {
    let bits: [bool; STATE_BITS] = state.to_le_bits();
    GameState {
        own_hand: read_mask(bits, OWN_HAND_OFFSET),
        opp_hand: read_mask(bits, OPP_HAND_OFFSET),
        loot: read_mask(bits, LOOT_OFFSET),
        current: read_uint(bits, CURRENT_OFFSET, 4),
        score: read_uint(bits, SCORE_OFFSET, 7),
        own_bids: read_bids(bits, OWN_BIDS_OFFSET),
        opp_bids: read_bids(bits, OPP_BIDS_OFFSET),
    }
}

fn count_set(mask: [bool; CARDS]) -> u8 {
    let mut count: u8 = 0;
    for i in 0..CARDS {
        count += mask[i] as u8;
    }
    count
}

fn is_card(bid: u8) -> bool {
    (bid >= 1) & (bid <= 9)
}

fn bids_match_hand(bids: [u8; CARDS], hand: [bool; CARDS]) -> bool {
    let mut matches = true;
    for c in 0..CARDS {
        let card = (c + 1) as u8;
        let mut uses: u8 = 0;
        for v in 0..CARDS {
            uses += (bids[v] == card) as u8;
        }
        matches = matches & (uses == (!hand[c]) as u8);
    }
    matches
}

pub fn validate_state(s: GameState, round: u8) {
    assert(round < 9, "round out of range");
    let remaining = 9 - round;
    assert(count_set(s.own_hand) == remaining, "own hand size does not match round");
    assert(count_set(s.opp_hand) == remaining, "opponent hand size does not match round");
    assert(count_set(s.loot) == remaining, "loot count does not match round");

    assert(is_card(s.current), "current loot out of range");
    assert(s.loot[(s.current - 1) as u32], "current loot is not remaining");

    let mut won: u8 = 0;
    let mut lost: u8 = 0;
    for v in 0..CARDS {
        let value = (v + 1) as u8;
        let own = s.own_bids[v];
        let opp = s.opp_bids[v];
        if s.loot[v] {
            assert((own == 0) & (opp == 0), "remaining loot has a recorded bid");
        } else {
            assert(is_card(own) & is_card(opp), "resolved loot has an invalid bid");
            won += ((own > opp) as u8) * value;
            lost += ((own < opp) as u8) * value;
        }
    }
    assert(bids_match_hand(s.own_bids, s.own_hand), "own bids do not match own hand");
    assert(bids_match_hand(s.opp_bids, s.opp_hand), "opponent bids do not match opponent hand");
    assert(SCORE_ZERO + won - lost == s.score, "score does not match history");
}

fn mask_feature(mask: [bool; CARDS], i: u32) -> Field {
    (mask[i] as Field) * ON
}

pub fn score_feature(score: u8) -> Field {
    let encoded = score as u32;
    let negative = encoded < SCORE_ZERO as u32;
    let magnitude = if negative {
        SCORE_ZERO as u32 - encoded
    } else {
        encoded - SCORE_ZERO as u32
    };
    let scaled = ((magnitude * 255 + 22) / 45) as Field;
    if negative {
        0 - scaled
    } else {
        scaled
    }
}

pub fn bid_feature(bid: u8) -> Field {
    (((bid as u32) * 255 + 4) / 9) as Field
}

pub fn features(s: GameState) -> [Field; NUM_FEATURES] {
    let mut x = [0; NUM_FEATURES];
    for i in 0..CARDS {
        x[i] = mask_feature(s.own_hand, i);
        x[9 + i] = mask_feature(s.opp_hand, i);
        x[18 + i] = mask_feature(s.loot, i);
        x[27 + i] = ((s.current == (i + 1) as u8) as Field) * ON;
        x[37 + i] = bid_feature(s.own_bids[i]);
        x[46 + i] = bid_feature(s.opp_bids[i]);
    }
    x[36] = score_feature(s.score);
    x
}
