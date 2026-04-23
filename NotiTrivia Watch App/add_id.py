import json
import uuid

input_path = "/Users/evanlevinsky/Desktop/Projects/NotiTrivia/NotiTrivia Watch App/FullyProcessedQuestions.json"
output_path = "/Users/evanlevinsky/Desktop/Projects/NotiTrivia/NotiTrivia Watch App/FullyProcessedQuestions_with_ids.json"

with open(input_path, "r", encoding="utf-8") as f:
    data = json.load(f)

for item in data:
    item["id"] = str(uuid.uuid4())
    item["times_used"] = 0

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)

print("Done. Output saved to:", output_path)