fn main(
    w: [u8; NW],
    b: [u32; NB],
    key: Field,
    salt: Field,
    public_inputs: [Field; 9],
    expected_features: [Field; 55],
    expected_z1: [Field; 128],
    expected_h1: [Field; 128],
    expected_z2: [Field; 128],
    expected_h2: [Field; 128],
    expected_z3: [Field; 9],
    expected_raw_tickets: [u32; 9],
    expected_tickets: [u32; 9],
    expected_total: u32,
    expected_model_digest: Field,
    expected_commitment: Field,
    expected_sample_hash: Field,
    expected_random_u64: u64,
    expected_ticket: u32,
    expected_action: u8,
) {
    let commitment_input = public_inputs[0];
    let state = public_inputs[1];
    let chain_field = public_inputs[2];
    let contract_address = public_inputs[3];
    let match_id = public_inputs[4];
    let player_field = public_inputs[5];
    let round_field = public_inputs[6];
    let seed = public_inputs[7];
    let action_field = public_inputs[8];

    chain_field.assert_max_bit_size::<64>();
    player_field.assert_max_bit_size::<8>();
    round_field.assert_max_bit_size::<8>();
    action_field.assert_max_bit_size::<8>();
    let chain_id = chain_field as u64;
    let player_id = player_field as u8;
    let round = round_field as u8;
    let action = action_field as u8;

    circuit_main(
        w,
        b,
        key,
        salt,
        commitment_input,
        state,
        chain_id,
        contract_address,
        match_id,
        player_id,
        round,
        seed,
        action,
    );

    let game = decode_state(state);
    let x = features(game);
    assert(x == expected_features, "features");

    let trace = forward(x, w, b);
    assert(trace.acc1 == expected_z1, "z1");
    assert(trace.hidden1 == expected_h1, "h1");
    assert(trace.acc2 == expected_z2, "z2");
    assert(trace.hidden2 == expected_h2, "h2");
    assert(trace.acc3 == expected_z3, "z3");
    assert(trace.tickets == expected_raw_tickets, "raw_tickets");

    let (tickets, total) = effective_tickets(trace.tickets, game.own_hand);
    assert(tickets == expected_tickets, "tickets");
    assert(total == expected_total, "total");

    assert(commitment::model_digest(w, b) == expected_model_digest, "model_digest");
    assert(commitment_hash(w, b, key, salt) == expected_commitment, "commitment");
    assert(commitment_input == expected_commitment, "public_commitment");

    let hash = sample_hash(
        key,
        chain_id,
        contract_address,
        match_id,
        player_id,
        round,
        seed,
    );
    assert(hash == expected_sample_hash, "sample_hash");
    assert(sampling::low_64_bits(hash) == expected_random_u64, "random_u64");
    assert(draw(hash, total) == expected_ticket, "ticket");
    assert(action == expected_action, "action");
}
