
// ignore_for_file: non_constant_identifier_names

// #OpImports
import '../ProjectNameEntityBase.dart';

// #TypeImports

class EntyClass extends ProjectNameEntityBase {
  EntyClass(dynamic client, dynamic entopts) : super(client, entopts) {
    name = 'entityname';
    name_ = 'entityname';
    Name = 'EntityName';
  }

  EntyClass make() {
    return EntyClass(client, entopts());
  }

  // #LoadOp

  // #ListOp

  // #CreateOp

  // #UpdateOp

  // #RemoveOp
}
