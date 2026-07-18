import fs from 'fs';
import * as XLSX from 'xlsx';

const filePath = 'C:\\Users\\akash\\OneDrive\\Desktop\\thegradnew\\test-data\\NatWest_Demo_Statement.xlsx';
const buffer = fs.readFileSync(filePath);

const wb = XLSX.read(buffer, { type: "buffer" });
const firstSheetName = wb.SheetNames[0];
const ws = wb.Sheets[firstSheetName];
const rows = XLSX.utils.sheet_to_json(ws, { header: 1 });

console.log('Dumping NatWest_Demo_Statement.xlsx first 10 rows:');
rows.slice(0, 15).forEach((r, idx) => console.log(`${idx}:`, r));
process.exit(0);
