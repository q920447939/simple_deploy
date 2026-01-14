import 'package:get/get.dart';

class NavController extends GetxController {
  final RxInt index = 0.obs;

  void select(int i) => index.value = i;
}
