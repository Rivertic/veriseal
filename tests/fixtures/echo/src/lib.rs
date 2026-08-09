// A deliberately tiny, dependency-free contract-like crate used to exercise
// veriseal's record/verify e2e path. Any change here must break `veriseal verify`.

pub fn ping() -> u32 {
    42
}
