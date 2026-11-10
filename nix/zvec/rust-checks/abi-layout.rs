use std::mem::{align_of, offset_of, size_of};
use zvec_rust_sys::*;
fn main() {
    println!(
        "{} {} {} {} {} {} {} {}",
        size_of::<zvec_pq_quantizer_params_t>(),
        align_of::<zvec_pq_quantizer_params_t>(),
        offset_of!(zvec_pq_quantizer_params_t, num_chunk),
        offset_of!(zvec_pq_quantizer_params_t, num_bits),
        offset_of!(zvec_pq_quantizer_params_t, enable_rotate),
        offset_of!(zvec_pq_quantizer_params_t, fast_scan),
        offset_of!(zvec_pq_quantizer_params_t, opq_iter),
        offset_of!(zvec_pq_quantizer_params_t, opq_pq_iter)
    );
    println!(
        "{} {} {} {} {}",
        size_of::<zvec_group_result_t>(),
        align_of::<zvec_group_result_t>(),
        offset_of!(zvec_group_result_t, group_by_value),
        offset_of!(zvec_group_result_t, docs),
        offset_of!(zvec_group_result_t, doc_count)
    );
    println!(
        "{} {}",
        size_of::<zvec_field_value_t>(),
        align_of::<zvec_field_value_t>()
    );
    println!(
        "{} {} {} {} {}",
        size_of::<zvec_doc_field_t>(),
        align_of::<zvec_doc_field_t>(),
        offset_of!(zvec_doc_field_t, name),
        offset_of!(zvec_doc_field_t, data_type),
        offset_of!(zvec_doc_field_t, value)
    );
}
