//! Regression coverage for the local v0.8.1 API additions to the pinned crates.
use std::sync::Once;
use zvec_rust::*;

fn init() {
    static INIT: Once = Once::new();
    INIT.call_once(|| initialize(None).unwrap());
}

#[test]
fn typed_fields_copy_their_data_and_reject_invalid_names() {
    init();
    let mut doc = Doc::new().unwrap();
    {
        let text = String::from("copied\0bytes");
        let binary = vec![0, 1, 255];
        let vector = vec![0.5, 1.0];
        doc.add_field("text", FieldValue::String(&text)).unwrap();
        doc.add_field("binary", FieldValue::Binary(&binary))
            .unwrap();
        doc.add_field("vector", FieldValue::VectorF32(&vector))
            .unwrap();
    }
    doc.add_field("bool", FieldValue::Bool(true)).unwrap();
    doc.add_field("int32", FieldValue::Int32(-42)).unwrap();
    doc.add_field("int64", FieldValue::Int64(i64::MIN)).unwrap();
    doc.add_field("uint32", FieldValue::Uint32(u32::MAX))
        .unwrap();
    doc.add_field("uint64", FieldValue::Uint64(u64::MAX))
        .unwrap();
    doc.add_field("float", FieldValue::Float(1.25)).unwrap();
    doc.add_field("double", FieldValue::Double(-2.5)).unwrap();
    assert_eq!(
        doc.get_string("text").unwrap().as_deref(),
        Some("copied\0bytes")
    );
    assert_eq!(doc.get_binary("binary").unwrap(), Some(vec![0, 1, 255]));
    assert_eq!(doc.get_vector_f32("vector").unwrap(), Some(vec![0.5, 1.0]));
    assert_eq!(doc.get_bool("bool").unwrap(), Some(true));
    assert_eq!(doc.get_i32("int32").unwrap(), Some(-42));
    assert_eq!(doc.get_i64("int64").unwrap(), Some(i64::MIN));
    assert_eq!(doc.get_u32("uint32").unwrap(), Some(u32::MAX));
    assert_eq!(doc.get_u64("uint64").unwrap(), Some(u64::MAX));
    assert_eq!(doc.get_f32("float").unwrap(), Some(1.25));
    assert_eq!(doc.get_f64("double").unwrap(), Some(-2.5));
    assert_eq!(
        doc.add_field("invalid\0name", FieldValue::Bool(true))
            .unwrap_err()
            .code,
        ErrorCode::InvalidArgument
    );
}

#[test]
fn pq_settings_round_trip_and_native_validation_rejects_bad_values() {
    init();
    let mut index = IndexParams::ivf(MetricType::L2, 4, 10, false).unwrap();
    index.set_quantize_type(QuantizeType::Pq).unwrap();
    let pq = PqQuantizerParams {
        num_chunk: 2,
        num_bits: 4,
        enable_rotate: true,
        fast_scan: true,
        opq_iter: 3,
        opq_pq_iter: 2,
    };
    index.set_quantizer_pq(&pq).unwrap();
    assert_eq!(index.quantize_type(), QuantizeType::Pq);
    assert_eq!(index.quantizer_pq().unwrap(), pq);
    assert_eq!(
        index
            .set_quantizer_pq(&PqQuantizerParams { num_bits: 7, ..pq })
            .unwrap_err()
            .code,
        ErrorCode::InvalidArgument
    );
    assert_eq!(index.quantizer_pq().unwrap(), pq);
    let mut hnsw = IndexParams::hnsw(MetricType::L2, 16, 200).unwrap();
    assert_eq!(
        hnsw.set_quantizer_pq(&pq).unwrap_err().code,
        ErrorCode::InvalidArgument
    );
    assert_eq!(
        hnsw.quantizer_pq().unwrap_err().code,
        ErrorCode::InvalidArgument
    );
}

#[test]
fn grouped_search_returns_owned_documents_and_honors_limits_and_filters() {
    init();
    let path = std::env::temp_dir().join(format!("zvec-rust-groups-{}", std::process::id()));
    let schema = CollectionSchema::builder("grouped")
        .add_indexed_field(
            "category",
            DataType::String,
            IndexParams::invert(false, false).unwrap(),
        )
        .add_vector_field(
            "embedding",
            DataType::VectorFp32,
            2,
            IndexParams::hnsw(MetricType::L2, 16, 200).unwrap(),
        )
        .build()
        .unwrap();
    let collection = Collection::create_and_open(path.to_str().unwrap(), &schema, None).unwrap();
    let mut docs = Vec::new();
    for (i, category) in ["a", "a", "b", "b"].iter().enumerate() {
        let mut doc = Doc::new().unwrap();
        doc.set_pk(&format!("doc{i}"));
        doc.add_field("category", FieldValue::String(category))
            .unwrap();
        doc.add_vector_f32("embedding", &[i as f32, 1.0]).unwrap();
        docs.push(doc);
    }
    assert_eq!(
        collection
            .insert(&docs.iter().collect::<Vec<_>>())
            .unwrap()
            .success_count,
        4
    );
    collection.flush().unwrap();
    let query = GroupBySearchQuery::new("embedding", "category", &[0.0, 1.0], 2, 1).unwrap();
    let groups = collection.group_by_query(&query).unwrap();
    assert_eq!(groups.len(), 2);
    let mut labels: Vec<_> = groups.iter().map(|g| g.group_by_value.as_str()).collect();
    labels.sort();
    assert_eq!(labels, ["a", "b"]);
    for group in &groups {
        assert_eq!(group.docs.len(), 1);
        assert_eq!(
            group.docs[0].get_string("category").unwrap().as_deref(),
            Some(group.group_by_value.as_str())
        );
    }
    let mut filtered = GroupBySearchQuery::new("embedding", "category", &[0.0, 1.0], 2, 1).unwrap();
    filtered.set_filter("category = 'absent'").unwrap();
    assert!(collection.group_by_query(&filtered).unwrap().is_empty());
    let invalid = GroupBySearchQuery::new("missing", "category", &[0.0, 1.0], 2, 1).unwrap();
    assert!(collection.group_by_query(&invalid).is_err());
    drop(query);
    collection.close().unwrap();
    // The native group arrays have already been freed, as have the collection
    // and query. These documents must retain independent ownership.
    assert_eq!(
        groups
            .iter()
            .find(|g| g.group_by_value == "a")
            .unwrap()
            .docs[0]
            .get_pk(),
        Some("doc0")
    );
    drop(groups);
    std::fs::remove_dir_all(path).unwrap();
}
