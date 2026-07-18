const query = async (msg) => {
  const res = await fetch('http://localhost:3000/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: msg })
  });
  console.log(`Q: "${msg}"`);
  console.log(`A:\n${await res.text()}\n`);
};

await query("how much money i have spend in total in shopping?");
await query("show me total money i have recieved");
process.exit(0);
