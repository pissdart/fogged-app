import 'package:fpdart/fpdart.dart';
import 'package:fogged/core/utils/exception_handler.dart';
import 'package:fogged/features/stats/model/stats_failure.dart';
import 'package:fogged/foggedcore/generated/v2/hcore/hcore.pb.dart';
import 'package:fogged/foggedcore/fogged_core_service.dart';
import 'package:fogged/utils/custom_loggers.dart';

abstract interface class StatsRepository {
  Stream<Either<StatsFailure, SystemInfo>> watchStats();
}

class StatsRepositoryImpl with ExceptionHandler, InfraLogger implements StatsRepository {
  StatsRepositoryImpl({required this.singbox});

  final FoggedCoreService singbox;

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() {
    return singbox.watchStats().handleExceptions(StatsUnexpectedFailure.new);
  }
}
