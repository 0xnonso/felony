use crate::state::NUM_FEATURES;

pub global NI: u32 = NUM_FEATURES;
pub global NH: u32 = 128;
pub global NO: u32 = 9;
pub global NW: u32 = NI * NH + NH * NH + NH * NO;
pub global NB: u32 = NH + NH + NO;

pub global L1_WEIGHTS: u32 = 0;
pub global L2_WEIGHTS: u32 = NI * NH;
pub global L3_WEIGHTS: u32 = NI * NH + NH * NH;
pub global L1_BIASES: u32 = 0;
pub global L2_BIASES: u32 = NH;
pub global L3_BIASES: u32 = NH + NH;

pub global HIDDEN_MAX: u64 = 255;
pub global TICKET_MAX: u64 = 65535;

global WEIGHT_OFFSET: Field = 128;
global BIAS_OFFSET: Field = 2147483648;
global ACC_OFFSET: Field = 1099511627776;
global ACC_OFFSET_INT: u64 = 1099511627776;

pub struct Trace {
    pub acc1: [Field; NH],
    pub hidden1: [Field; NH],
    pub acc2: [Field; NH],
    pub hidden2: [Field; NH],
    pub acc3: [Field; NO],
    pub tickets: [u32; NO],
}

pub fn shifted_accumulator(acc: Field) -> u64 {
    let shifted = acc + ACC_OFFSET;
    shifted.assert_max_bit_size::<41>();
    shifted as u64
}

pub fn requantize(acc: Field, max: u64) -> u64 {
    let shifted = shifted_accumulator(acc);
    let positive = if shifted > ACC_OFFSET_INT {
        shifted - ACC_OFFSET_INT
    } else {
        0
    };
    let rounded = (positive + 128) >> 8;
    if rounded > max {
        max
    } else {
        rounded
    }
}

fn layer<let I: u32, let O: u32>(
    x: [Field; I],
    w: [u8; NW],
    weight_start: u32,
    b: [u32; NB],
    bias_start: u32,
) -> [Field; O] {
    let mut out = [0; O];
    for o in 0..O {
        let mut acc = b[bias_start + o] as Field - BIAS_OFFSET;
        for i in 0..I {
            acc += (w[weight_start + o * I + i] as Field - WEIGHT_OFFSET) * x[i];
        }
        out[o] = acc;
    }
    out
}

fn hidden_activations(acc: [Field; NH]) -> [Field; NH] {
    let mut out = [0; NH];
    for i in 0..NH {
        out[i] = requantize(acc[i], HIDDEN_MAX) as Field;
    }
    out
}

pub fn forward(x: [Field; NI], w: [u8; NW], b: [u32; NB]) -> Trace {
    let acc1: [Field; NH] = layer(x, w, L1_WEIGHTS, b, L1_BIASES);
    let hidden1 = hidden_activations(acc1);
    let acc2: [Field; NH] = layer(hidden1, w, L2_WEIGHTS, b, L2_BIASES);
    let hidden2 = hidden_activations(acc2);
    let acc3: [Field; NO] = layer(hidden2, w, L3_WEIGHTS, b, L3_BIASES);

    let mut tickets = [0; NO];
    for i in 0..NO {
        tickets[i] = requantize(acc3[i], TICKET_MAX) as u32;
    }
    Trace { acc1, hidden1, acc2, hidden2, acc3, tickets }
}
