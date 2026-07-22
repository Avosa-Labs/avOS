(module
  (import "wasi_snapshot_preview1" "sock_send"
    (func $send (param i32 i32 i32 i32 i32) (result i32)))
  (func (export "run") (result i32) i32.const 0))
