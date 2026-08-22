package JAVAPACKAGE.core;

/** Minimal entity contract used by the result pipeline (list wrapping). */
public interface Entity {

  String getName();

  Entity make();

  Object data(Object... args);

  Object match(Object... args);
}
