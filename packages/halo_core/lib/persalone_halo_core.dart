/// Pure-Dart Halo core shared by the mobile app and local hosts: bounded
/// display commands, caption composition, the device adapter and the
/// transport port. Platform transports (BLE, emulator) live elsewhere.
library;

export 'src/halo_bounded_display.dart';
export 'src/halo_caption_composer.dart';
export 'src/halo_caption_output_adapter.dart';
export 'src/halo_device_adapter.dart';
export 'src/halo_transport.dart';
export 'src/scripted_halo_fixture.dart';
