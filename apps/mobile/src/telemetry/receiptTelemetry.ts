export async function withReceiptSpan<T>(
  _name: string,
  _attributes: Record<string, string | number | boolean>,
  operation: () => Promise<T>,
): Promise<T> {
  return operation();
}
