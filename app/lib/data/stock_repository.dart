// إدارة حركات المخزون وتسجيل الرصيد قبل الحركة وبعدها داخل معاملة ذرية.
import 'package:sqflite/sqflite.dart';

class StockMovement {
  const StockMovement({
    required this.id,
    required this.productId,
    required this.movementType,
    required this.quantityDelta,
    required this.stockBefore,
    required this.stockAfter,
    required this.createdAt,
    this.productName,
    this.note,
    this.referenceType,
    this.referenceId,
  });

  final int id;
  final int productId;
  final String movementType;
  final double quantityDelta;
  final double stockBefore;
  final double stockAfter;
  final String createdAt;
  final String? productName;
  final String? note;
  final String? referenceType;
  final int? referenceId;

  factory StockMovement.fromMap(Map<String, Object?> row) => StockMovement(
        id: row['id'] as int,
        productId: row['product_id'] as int,
        movementType: row['movement_type'] as String,
        quantityDelta: (row['quantity_delta'] as num).toDouble(),
        stockBefore: (row['stock_before'] as num).toDouble(),
        stockAfter: (row['stock_after'] as num).toDouble(),
        createdAt: row['created_at'] as String,
        productName: row['product_name'] as String?,
        note: row['note'] as String?,
        referenceType: row['reference_type'] as String?,
        referenceId: row['reference_id'] as int?,
      );
}

class StockRepository {
  StockRepository(this._database);

  final Database _database;

  static const movementTypes = <String>{
    'إضافة',
    'تسوية',
    'مرتجع بيع',
    'مرتجع شراء',
    'بيع',
  };

  /// يسجل الحركة ويحدّث رصيد الصنف في معاملة واحدة.
  Future<StockMovement> recordMovement({
    required int productId,
    required String movementType,
    required double quantityDelta,
    String? note,
    String? referenceType,
    int? referenceId,
  }) async {
    if (!movementTypes.contains(movementType)) {
      throw ArgumentError('نوع حركة المخزون غير معروف.');
    }
    if (!quantityDelta.isFinite || quantityDelta == 0) {
      throw ArgumentError('كمية الحركة يجب أن تكون رقمًا صالحًا وغير صفرية.');
    }

    return _database.transaction((txn) async {
      final rows = await txn.query(
        'products',
        columns: ['id', 'stock_quantity'],
        where: 'id = ?',
        whereArgs: [productId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('الصنف غير موجود.');

      final before = (rows.first['stock_quantity'] as num).toDouble();
      final after = before + quantityDelta;
      await txn.update(
        'products',
        {'stock_quantity': after},
        where: 'id = ?',
        whereArgs: [productId],
      );
      final now = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('stock_movements', {
        'product_id': productId,
        'movement_type': movementType,
        'quantity_delta': quantityDelta,
        'stock_before': before,
        'stock_after': after,
        'note': note?.trim().isEmpty == true ? null : note?.trim(),
        'reference_type': referenceType,
        'reference_id': referenceId,
        'created_at': now,
      });
      return StockMovement(
        id: id,
        productId: productId,
        movementType: movementType,
        quantityDelta: quantityDelta,
        stockBefore: before,
        stockAfter: after,
        createdAt: now,
        note: note?.trim().isEmpty == true ? null : note?.trim(),
        referenceType: referenceType,
        referenceId: referenceId,
      );
    });
  }

  /// يعرض سجل صنف محدد أو سجل جميع الأصناف من الأحدث إلى الأقدم.
  /// تمرير null يعرض كل الأصناف دون تعديل أي رصيد.
  Future<List<StockMovement>> history(int? productId, {int limit = 100}) async {
    if (limit < 1) throw ArgumentError('عدد الحركات يجب أن يكون أكبر من صفر.');
    final rows = await _database.rawQuery(
      '''
      SELECT sm.*, p.name AS product_name
      FROM stock_movements sm
      LEFT JOIN products p ON p.id = sm.product_id
      ${productId == null ? '' : 'WHERE sm.product_id = ?'}
      ORDER BY sm.id DESC
      LIMIT ?
      ''',
      productId == null ? [limit] : [productId, limit],
    );
    return rows.map(StockMovement.fromMap).toList(growable: false);
  }
}
