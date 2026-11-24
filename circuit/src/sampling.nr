use crate::commitment::SPEC_VERSION;
use crate::network::NO;
use poseidon::poseidon2::Poseidon2;

pub global DOMAIN_SAMPLE: Field = 203;
global SAMPLE_INPUTS: u32 = 9;
global FIELD_BITS: u32 = 254;
global DRAW_BITS: u32 = 64;

pub fn sample_hash(
    key: Field,
    chain_id: u64,
    contract_address: Field,
    match_id: Field,
    player_id: u8,
    round: u8,
    seed: Field,
) -> Field {
    Poseidon2::hash(
        [
            DOMAIN_SAMPLE,
            SPEC_VERSION,
            key,
            chain_id as Field,
            contract_address,
            match_id,
            player_id as Field,
            round as Field,
            seed,
        ],
        SAMPLE_INPUTS,
    )
}

pub fn low_64_bits(hash: Field) -> u64 {
    let bits: [bool; FIELD_BITS] = hash.to_le_bits();
    let mut value: u64 = 0;
    let mut place: u64 = 1;
    for i in 0..DRAW_BITS {
        value += (bits[i] as u64) * place;
        if i + 1 < DRAW_BITS {
            place *= 2;
        }
    }
    value
}

pub fn draw(hash: Field, total: u32) -> u32 {
    assert(total > 0, "ticket total is zero");
    (low_64_bits(hash) % (total as u64)) as u32
}

pub fn effective_tickets(raw: [u32; NO], hand: [bool; NO]) -> ([u32; NO], u32) {
    let mut tickets = [0; NO];
    let mut total: u32 = 0;
    for i in 0..NO {
        tickets[i] = (hand[i] as u32) * raw[i];
        total += tickets[i];
    }
    if total == 0 {
        let mut found = false;
        for i in 0..NO {
            if hand[i] & !found {
                tickets[i] = 1;
                total = 1;
                found = true;
            }
        }
    }
    (tickets, total)
}

pub fn assert_selected(tickets: [u32; NO], r: u32, action: u8) {
    let mut before: u32 = 0;
    for i in 0..NO {
        before += ((i as u8 < action) as u32) * tickets[i];
    }
    assert(before <= r, "action is not the sampled card");
    assert(r < before + tickets[action as u32], "action is not the sampled card");
}
