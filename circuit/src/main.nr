mod commitment;
mod network;
mod sampling;
mod state;
mod tests;

use commitment::commitment_hash;
use network::{forward, NB, NW};
use sampling::{assert_selected, draw, effective_tickets, sample_hash};
use state::{decode_state, features, validate_state};

pub fn validate_context(key: Field, contract_address: Field, player_id: u8, round: u8, action: u8) {
    assert(key != 0, "sampling key is zero");
    contract_address.assert_max_bit_size::<160>();
    assert(player_id < 2, "player id out of range");
    assert(round < 9, "round out of range");
    assert(action < 9, "action out of range");
}

fn main(
    w: [u8; NW],
    b: [u32; NB],
    key: Field,
    salt: Field,
    commitment: pub Field,
    state: pub Field,
    chain_id: pub u64,
    contract_address: pub Field,
    match_id: pub Field,
    player_id: pub u8,
    round: pub u8,
    seed: pub Field,
    action: pub u8,
) {
    validate_context(key, contract_address, player_id, round, action);
    assert(commitment_hash(w, b, key, salt) == commitment, "commitment mismatch");

    let game = decode_state(state);
    validate_state(game, round);

    let trace = forward(features(game), w, b);
    let (tickets, total) = effective_tickets(trace.tickets, game.own_hand);

    let hash = sample_hash(
        key,
        chain_id,
        contract_address,
        match_id,
        player_id,
        round,
        seed,
    );
    assert_selected(tickets, draw(hash, total), action);
}
