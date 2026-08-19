CREATE DATABASE IF NOT EXISTS eventhub_catalog;
USE eventhub_catalog;

CREATE TABLE IF NOT EXISTS catalog_event (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(255) NOT NULL,
  price DECIMAL(10, 2) NOT NULL
);

INSERT INTO catalog_event (title, price) VALUES
  ('Campus Tech Meetup', 0.00),
  ('Intro to Distributed Systems', 15.00),
  ('Career Fair: Software Engineering', 25.00),
  ('End of Semester Concert', 10.00);
