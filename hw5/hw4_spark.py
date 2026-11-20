from pyspark.sql import SparkSession, functions as F

spark = SparkSession.builder.appName("HW4_Spark_YARN_Hive").enableHiveSupport().getOrCreate()
spark.sparkContext.setLogLevel("WARN")
df = spark.sql("SELECT * FROM hw3.sales")
df.printSchema()

df_transform = (df.withColumn("sale_year", F.col("sale_year").cast("int"))
    .withColumn("amount", F.col("amount").cast("double"))
    .withColumn("city", F.col("city").cast("string"))
    .filter(F.col("amount") > 0)
    .filter(F.col("sale_year").isNotNull()))

df_agg = df_transform.groupBy("sale_year", "city").agg(
    F.sum("amount").alias("total_amount"),
    F.count("*").alias("sales_count"),
    F.avg("amount").alias("avg_amount"),
)
print("результат агрегации")
df_agg.show(10, truncate=False)

spark.sql("CREATE DATABASE IF NOT EXISTS hw4")
(df_agg.write.mode("overwrite").format("orc").partitionBy("sale_year").saveAsTable("hw4.sales_agg"))
print("создана таблица hw4.sales_agg")

spark.sql("SELECT * FROM hw4.sales_agg ORDER BY sale_year, city LIMIT 10").show(truncate=False)
spark.stop()
