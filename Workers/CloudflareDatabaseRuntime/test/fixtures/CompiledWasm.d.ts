declare module "*.wasm" {
  const program: WebAssembly.Module;
  export default program;
}
