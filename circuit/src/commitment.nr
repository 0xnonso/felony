use crate::network::{NB, NW};
use poseidon::poseidon2::Poseidon2;

pub global SPEC_VERSION: Field = 1;
pub global DOMAIN_MODEL: Field = 201;
pub global DOMAIN_COMMIT: Field = 202;

pub global BYTES_PER_FIELD: u32 = 31;
pub global NP: u32 = (NW + BYTES_PER_FIELD - 1) / BYTES_PER_FIELD;
global MODEL_INPUTS: u32 = 2 + NP + NB;
global COMMIT_INPUTS: u32 = 5;

pub fn pack_weights(w: [u8; NW]) -> [Field; NP] {
    let mut packed = [0; NP];
    for j in 0..NP {
        let mut acc: Field = 0;
        for reversed in 0..BYTES_PER_FIELD {
            let index = j * BYTES_PER_FIELD + (BYTES_PER_FIELD - 1 - reversed);
            acc *= 256;
            if index < NW {
                acc += w[index] as Field;
            }
        }
        packed[j] = acc;
    }
    packed
}

pub fn model_digest(w: [u8; NW], b: [u32; NB]) -> Field {
    let packed = pack_weights(w);
    let mut input = [0; MODEL_INPUTS];
    input[0] = DOMAIN_MODEL;
    input[1] = SPEC_VERSION;
    for i in 0..NP {
        input[2 + i] = packed[i];
    }
    for i in 0..NB {
        input[2 + NP + i] = b[i] as Field;
    }
    Poseidon2::hash(input, MODEL_INPUTS)
}

pub fn commitment_from_digest(digest: Field, key: Field, salt: Field) -> Field {
    Poseidon2::hash(
        [DOMAIN_COMMIT, SPEC_VERSION, digest, key, salt],
        COMMIT_INPUTS,
    )
}

pub fn commitment_hash(w: [u8; NW], b: [u32; NB], key: Field, salt: Field) -> Field {
    commitment_from_digest(model_digest(w, b), key, salt)
}
