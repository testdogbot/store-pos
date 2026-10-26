class Product {
  final String barcode;
  String name;
  int priceCents; // 价格，单位：分
  int stock;

  Product({required this.barcode, required this.name, required this.priceCents, this.stock = 0});

  factory Product.fromMap(Map<String, Object?> m) => Product(
        barcode: m['barcode'] as String,
        name: m['name'] as String,
        priceCents: (m['price_cents'] as num).toInt(),
        stock: (m['stock'] as num).toInt(),
      );
}

class CartItem {
  final Product product;
  int qty;
  CartItem(this.product, [this.qty = 1]);
  int get subtotal => product.priceCents * qty;
}

String yuan(int cents) => '¥${(cents / 100).toStringAsFixed(2)}';

int? parseYuan(String s) {
  final v = double.tryParse(s.trim());
  return v == null ? null : (v * 100).round();
}
