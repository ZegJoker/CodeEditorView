/* Fixture for real clangd integration (LSP-N13). */
int add(int a, int b) {
  return a + b;
}

int main(void) {
  return add(1, 2);
}
