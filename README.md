# barcode-db
小店收银用的商品条码库分片，按条码前 6 位分文件：`d/<前6位>.json`，值为 `[名称, 规格, 品牌, 参考价(分), 厂商]`。
数据来源：https://github.com/EricLiuCN/barcode （商品 100 万条 + 药品 4 万条）。
