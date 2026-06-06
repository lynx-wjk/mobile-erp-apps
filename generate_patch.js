const fs = require('fs');
let sql = fs.readFileSync('temp_snap.sql', 'utf-8');

sql = sql.replace(/finance_anomaly_search_v24_6_82e/g, 'finance_abnormal_search_v1');
sql = sql.replace(/anomaly_status/g, 'abnormal_status');
sql = sql.replace(/anomaly_aggregates/g, 'abnormal_aggregates');
sql = sql.replace(/anomaly_report/g, 'abnormal_report');
sql = sql.replace(/v_anomaly/g, 'v_abnormal');
sql = sql.replace(/v_anomalies/g, 'v_abnormals');
sql = sql.replace(/'anomalies'/g, '\'abnormals\'');
sql = sql.replace(/'anomaly_count'/g, '\'abnormal_count\'');
sql = sql.replace(/'anomaly_total'/g, '\'abnormal_total\'');
sql = sql.replace(/'anomaly_status_counts'/g, '\'abnormal_status_counts\'');

sql = sql.replace(
  /not like all \(array\['%CANCEL%', '%UNPAID%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%'\]\)/g,
  "not like all (array['%CANCEL%', '%UNPAID%', '%FULL_REFUND%', '%FULL_RETURN%', '%FAILED%', '%CLOSE%'])"
);

sql = sql.replace(/where abnormal_status <> 'OK'/g, "where abnormal_status in ('NEGATIVE_PAYOUT', 'LOW_MARGIN')");

fs.writeFileSync('patch_finance_abnormal.sql', sql);
console.log('Patch generated.');
