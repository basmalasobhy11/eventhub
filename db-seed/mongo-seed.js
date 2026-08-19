// Run with: mongosh eventhub_bookings db-seed/mongo-seed.js
db.bookings.insertMany([
  { id: "seed-1", userId: "demo-user", eventId: 1, status: "confirmed" },
  { id: "seed-2", userId: "demo-user", eventId: 3, status: "confirmed" },
]);
