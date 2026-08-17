class SourceFailure implements Exception {
  const SourceFailure(this.message, {this.retryable = true});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}
