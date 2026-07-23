import type { DatabaseRuntimeInstance } from "./DatabaseRuntimeInstance";
import type {
  DatabaseRuntimeInstantiationOptions,
  DatabaseRuntimeInstantiator,
} from "./DatabaseRuntimeTypes";

export const instantiateDatabaseRuntime: DatabaseRuntimeInstantiator = async (
  options: DatabaseRuntimeInstantiationOptions
): Promise<DatabaseRuntimeInstance> => {
  const runtimeServices: WebAssembly.Imports = {
    wasi_snapshot_preview1: options.wasi.services,
  };
  options.registerRuntimeServices(runtimeServices);
  const executableInstance = await WebAssembly.instantiate(
    options.program,
    runtimeServices
  );
  return { endpoints: executableInstance.exports };
};
