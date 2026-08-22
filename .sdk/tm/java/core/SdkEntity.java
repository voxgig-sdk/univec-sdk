package JAVAPACKAGE.core;

import java.util.Map;
import java.util.stream.Stream;

/**
 * The full CRUD entity contract of the Univec SDK. Every generated
 * entity implements every operation; unsupported operations throw an
 * SdkError at runtime (see Helpers.unsupportedOp).
 */
public interface SdkEntity extends Entity {

  Object load(Map<String, Object> reqmatch, Map<String, Object> ctrl);

  Object list(Map<String, Object> reqmatch, Map<String, Object> ctrl);

  Object create(Map<String, Object> reqdata, Map<String, Object> ctrl);

  Object update(Map<String, Object> reqdata, Map<String, Object> ctrl);

  Object remove(Map<String, Object> reqmatch, Map<String, Object> ctrl);

  // Runs `action` through the pipeline and returns a Stream over result
  // items (the streaming feature's incremental output when active, else the
  // materialised items). See EntityBase.stream.
  Stream<Object> stream(String action, Map<String, Object> args,
      Map<String, Object> callopts);
}
