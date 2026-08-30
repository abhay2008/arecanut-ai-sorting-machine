import os
import glob
import cv2
import shutil
import numpy as np
from pathlib import Path
from ultralytics import YOLO

def auto_detect_nut_bbox(img_path):
    """
    Locate bounding box of arecanut in image using OpenCV saliency & color thresholding
    Returns (x_center, y_center, w, h) in normalized [0, 1] range.
    """
    img = cv2.imread(img_path)
    if img is None:
        return None

    h_img, w_img, _ = img.shape

    # Convert to HSV color space
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)

    # Color threshold for brown/orange/reddish nut or green nut
    # Hue: 0..30 (brownish/reddish), 35..85 (greenish nut)
    mask1 = cv2.inRange(hsv, np.array([0, 20, 20]), np.array([30, 255, 255]))
    mask2 = cv2.inRange(hsv, np.array([35, 20, 20]), np.array([85, 255, 255]))
    mask = cv2.bitwise_or(mask1, mask2)

    # Morphological clean up
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    valid_boxes = []
    for cnt in contours:
        area = cv2.contourArea(cnt)
        if area > 1000: # Filter out tiny noise
            x, y, w, h = cv2.boundingRect(cnt)
            valid_boxes.append((x, y, w, h, area))

    if not valid_boxes:
        # Fallback to center bounding box if thresholding misses
        bw = w_img * 0.4
        bh = h_img * 0.4
        cx = 0.5
        cy = 0.5
        return (cx, cy, bw / w_img, bh / h_img)

    # Pick largest contour
    valid_boxes.sort(key=lambda b: b[4], reverse=True)
    x, y, w, h, _ = valid_boxes[0]

    # Convert to normalized YOLO format (x_center, y_center, width, height)
    x_center = (x + w / 2.0) / w_img
    y_center = (y + h / 2.0) / h_img
    norm_w = w / w_img
    norm_h = h / h_img

    return (x_center, y_center, norm_w, norm_h)

def prepare_yolo_dataset(raw_dataset_dir, output_yolo_dir):
    """
    Prepare YOLO formatted dataset directory with images and labels
    """
    if os.path.exists(output_yolo_dir):
        shutil.rmtree(output_yolo_dir)

    for split in ['train', 'val']:
        os.makedirs(os.path.join(output_yolo_dir, 'images', split), exist_ok=True)
        os.makedirs(os.path.join(output_yolo_dir, 'labels', split), exist_ok=True)

    nut_files = glob.glob(os.path.join(raw_dataset_dir, 'nut_present', '**', '*.jpg'), recursive=True)
    no_nut_files = glob.glob(os.path.join(raw_dataset_dir, 'no_nut', '**', '*.jpg'), recursive=True)

    all_files = []
    for p in nut_files:
        all_files.append((p, 1)) # 1 = nut_present (class 0: nut)
    for p in no_nut_files:
        all_files.append((p, 0)) # 0 = no_nut (background)

    # 80/20 train/val split
    np.random.seed(42)
    np.random.shuffle(all_files)
    split_idx = int(len(all_files) * 0.8)

    train_files = all_files[:split_idx]
    val_files = all_files[split_idx:]

    print(f"Total dataset: {len(all_files)} images ({len(train_files)} train, {len(val_files)} val)")

    for split_name, files in [('train', train_files), ('val', val_files)]:
        for idx, (img_path, class_label) in enumerate(files):
            fname = f"img_{split_name}_{idx:03d}.jpg"
            dst_img_path = os.path.join(output_yolo_dir, 'images', split_name, fname)
            dst_label_path = os.path.join(output_yolo_dir, 'labels', split_name, f"img_{split_name}_{idx:03d}.txt")

            shutil.copy(img_path, dst_img_path)

            if class_label == 1:
                bbox = auto_detect_nut_bbox(img_path)
                if bbox is not None:
                    cx, cy, w, h = bbox
                    with open(dst_label_path, 'w') as f:
                        f.write(f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}\n")
                else:
                    open(dst_label_path, 'w').close()
            else:
                # Background image (no nut) - empty label file
                open(dst_label_path, 'w').close()

    # Create dataset.yaml
    yaml_content = f"""
path: {os.path.abspath(output_yolo_dir)}
train: images/train
val: images/val

names:
  0: nut
"""
    yaml_path = os.path.join(output_yolo_dir, 'dataset.yaml')
    with open(yaml_path, 'w') as f:
        f.write(yaml_content)

    print(f"YOLO Dataset ready at '{output_yolo_dir}' (yaml: '{yaml_path}')")
    return yaml_path

def main():
    raw_dataset = "/Users/abhay/Desktop/arecanut_final/binary_dataset/BinaryDetector"
    yolo_dir = "/Users/abhay/Desktop/arecanut_final/yolo_dataset"
    export_dir = "/Users/abhay/Desktop/arecanut_final/tflite_output"
    os.makedirs(export_dir, exist_ok=True)

    print("=== Step 1: Preparing YOLO Dataset ===")
    yaml_path = prepare_yolo_dataset(raw_dataset, yolo_dir)

    print("\n=== Step 2: Training Fine-Tuned YOLOv8 Nano Model ===")
    model = YOLO("yolov8n.pt") # Start from pretrained YOLOv8n weights

    results = model.train(
        data=yaml_path,
        epochs=40,
        imgsz=320,
        batch=8,
        project="/Users/abhay/Desktop/arecanut_final/yolo_runs",
        name="arecanut_detector",
        exist_ok=True,
        lr0=0.005,
        hsv_h=0.015,
        hsv_s=0.7,
        hsv_v=0.4,
        degrees=15.0,
        fliplr=0.5,
        mosaic=0.5
    )

    print("\n=== Step 3: Evaluating Fine-Tuned Detector ===")
    val_results = model.val()
    print(f"Validation mAP@50: {val_results.box.map50 * 100:.2f}%")
    print(f"Validation mAP@50-95: {val_results.box.map * 100:.2f}%")

    print("\n=== Step 4: Exporting Model to TFLite ===")
    exported_path = model.export(format="tflite", imgsz=320, int8=False)
    print(f"Exported TFLite model: {exported_path}")

    # Copy to tflite_output
    if exported_path and os.path.exists(exported_path):
        dst = os.path.join(export_dir, "arecanut_yolo_detector.tflite")
        shutil.copy(exported_path, dst)
        print(f"Saved TFLite model to '{dst}' ({os.path.getsize(dst)/1024:.2f} KB)")

if __name__ == "__main__":
    main()
