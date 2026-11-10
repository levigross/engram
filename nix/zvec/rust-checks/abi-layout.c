#include <stddef.h>
#include <stdio.h>
#include <zvec/c_api.h>
int main(void) {
    printf("%zu %zu %zu %zu %zu %zu %zu %zu\n", sizeof(zvec_pq_quantizer_params_t), _Alignof(zvec_pq_quantizer_params_t), offsetof(zvec_pq_quantizer_params_t, num_chunk), offsetof(zvec_pq_quantizer_params_t, num_bits), offsetof(zvec_pq_quantizer_params_t, enable_rotate), offsetof(zvec_pq_quantizer_params_t, fast_scan), offsetof(zvec_pq_quantizer_params_t, opq_iter), offsetof(zvec_pq_quantizer_params_t, opq_pq_iter));
    printf("%zu %zu %zu %zu %zu\n", sizeof(zvec_group_result_t), _Alignof(zvec_group_result_t), offsetof(zvec_group_result_t, group_by_value), offsetof(zvec_group_result_t, docs), offsetof(zvec_group_result_t, doc_count));
    printf("%zu %zu\n", sizeof(zvec_field_value_t), _Alignof(zvec_field_value_t));
    printf("%zu %zu %zu %zu %zu\n", sizeof(zvec_doc_field_t), _Alignof(zvec_doc_field_t), offsetof(zvec_doc_field_t, name), offsetof(zvec_doc_field_t, data_type), offsetof(zvec_doc_field_t, value));
    return 0;
}
