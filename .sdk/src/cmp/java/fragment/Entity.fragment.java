package JAVAPACKAGE.entity;

import java.util.LinkedHashMap;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Entity;
import JAVAPACKAGE.core.Helpers;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.utility.struct.Struct;

/** EntityName entity client for the ProjectName SDK. */
@SuppressWarnings({"unchecked", "unused"})
public class EntyClass extends EntityBase {

  public EntyClass(SdkClient client, Map<String, Object> entopts) {
    super("entityname", client, entopts);
  }

  @Override
  public Entity make() {
    Map<String, Object> opts = new LinkedHashMap<>(this.entopts);
    return new EntyClass(this.client, opts);
  }

// #LoadOp

// #ListOp

// #CreateOp

// #UpdateOp

// #RemoveOp
}
