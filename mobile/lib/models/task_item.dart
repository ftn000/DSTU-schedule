import 'package:flutter/material.dart';

/// Модель прикрепленного файла (методичка к заданию или файл решения студента)
class TaskFile {
  final int id;
  final int taskId;
  final int? submissionId;
  final String fileType; // 'task_attachment' или 'submission_attachment'
  final String filename;
  final String? storedFilename;
  final int fileSize;
  final String? mimeType;
  final String? uploadedBy;
  final String? createdAt;

  TaskFile({
    required this.id,
    required this.taskId,
    this.submissionId,
    required this.fileType,
    required this.filename,
    this.storedFilename,
    required this.fileSize,
    this.mimeType,
    this.uploadedBy,
    this.createdAt,
  });

  factory TaskFile.fromJson(Map<String, dynamic> json) {
    return TaskFile(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      taskId: json['task_id'] is int ? json['task_id'] : int.tryParse(json['task_id'].toString()) ?? 0,
      submissionId: json['submission_id'] != null ? int.tryParse(json['submission_id'].toString()) : null,
      fileType: json['file_type']?.toString() ?? 'task_attachment',
      filename: json['filename']?.toString() ?? 'file',
      storedFilename: json['stored_filename']?.toString(),
      fileSize: json['file_size'] is int ? json['file_size'] : int.tryParse(json['file_size'].toString()) ?? 0,
      mimeType: json['mime_type']?.toString(),
      uploadedBy: json['uploaded_by']?.toString(),
      createdAt: json['created_at']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'task_id': taskId,
      'submission_id': submissionId,
      'file_type': fileType,
      'filename': filename,
      'stored_filename': storedFilename,
      'file_size': fileSize,
      'mime_type': mimeType,
      'uploaded_by': uploadedBy,
      'created_at': createdAt,
    };
  }

  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData get icon {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf;
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) return Icons.description;
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z')) return Icons.folder_zip;
    if (lower.endsWith('.dart') ||
        lower.endsWith('.py') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.c') ||
        lower.endsWith('.cs') ||
        lower.endsWith('.java') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.html') ||
        lower.endsWith('.css') ||
        lower.endsWith('.sql')) {
      return Icons.code;
    }
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return Icons.image;
    return Icons.insert_drive_file;
  }
}

/// Статус выполнения задания студентом
enum TaskStatus {
  todo,
  inProgress,
  submitted,
  accepted,
}

extension TaskStatusExtension on TaskStatus {
  String get code {
    switch (this) {
      case TaskStatus.todo:
        return 'todo';
      case TaskStatus.inProgress:
        return 'in_progress';
      case TaskStatus.submitted:
        return 'submitted';
      case TaskStatus.accepted:
        return 'accepted';
    }
  }

  String get label {
    switch (this) {
      case TaskStatus.todo:
        return 'Не начато';
      case TaskStatus.inProgress:
        return 'В процессе';
      case TaskStatus.submitted:
        return 'Сдано';
      case TaskStatus.accepted:
        return 'Зачтено';
    }
  }

  Color get color {
    switch (this) {
      case TaskStatus.todo:
        return Colors.grey;
      case TaskStatus.inProgress:
        return const Color(0xFFFFA726); // Amber/Orange
      case TaskStatus.submitted:
        return const Color(0xFF42A5F5); // Blue
      case TaskStatus.accepted:
        return const Color(0xFF66BB6A); // Green
    }
  }

  static TaskStatus fromString(String? val) {
    switch (val?.toLowerCase().trim()) {
      case 'in_progress':
      case 'inprogress':
        return TaskStatus.inProgress;
      case 'submitted':
        return TaskStatus.submitted;
      case 'accepted':
      case 'done':
        return TaskStatus.accepted;
      default:
        return TaskStatus.todo;
    }
  }
}

/// Решение студента
class StudentSubmission {
  final int? id;
  final int taskId;
  final String studentId;
  TaskStatus status;
  String textSolution;
  String? grade;
  String? updatedAt;
  List<TaskFile> files;

  StudentSubmission({
    this.id,
    required this.taskId,
    required this.studentId,
    required this.status,
    required this.textSolution,
    this.grade,
    this.updatedAt,
    this.files = const [],
  });

  factory StudentSubmission.fromJson(Map<String, dynamic> json) {
    return StudentSubmission(
      id: json['id'] != null ? int.tryParse(json['id'].toString()) : null,
      taskId: json['task_id'] is int ? json['task_id'] : int.tryParse(json['task_id'].toString()) ?? 0,
      studentId: json['student_id']?.toString() ?? '',
      status: TaskStatusExtension.fromString(json['status']?.toString()),
      textSolution: json['text_solution']?.toString() ?? '',
      grade: json['grade']?.toString(),
      updatedAt: json['updated_at']?.toString(),
      files: (json['files'] as List<dynamic>?)
              ?.map((f) => TaskFile.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'task_id': taskId,
      'student_id': studentId,
      'status': status.code,
      'text_solution': textSolution,
      'grade': grade,
      'updated_at': updatedAt,
      'files': files.map((f) => f.toJson()).toList(),
    };
  }
}

/// Задание или практическая работа
class TaskItem {
  final int id;
  final String groupName;
  final String subject;
  final String title;
  final String lessonType;
  final int? lessonNum;
  final String? lessonDate;
  final String? description;
  final String? deadline;
  final String? createdBy;
  final String createdAt;
  final String updatedAt;
  final List<TaskFile> taskFiles;
  StudentSubmission? submission;

  TaskItem({
    required this.id,
    required this.groupName,
    required this.subject,
    required this.title,
    this.lessonType = 'Практика',
    this.lessonNum,
    this.lessonDate,
    this.description,
    this.deadline,
    this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.taskFiles = const [],
    this.submission,
  });

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    return TaskItem(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id'].toString()) ?? 0,
      groupName: json['group_name']?.toString() ?? '',
      subject: json['subject']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      lessonType: json['lesson_type']?.toString() ?? 'Практика',
      lessonNum: json['lesson_num'] != null ? int.tryParse(json['lesson_num'].toString()) : null,
      lessonDate: json['lesson_date']?.toString(),
      description: json['description']?.toString(),
      deadline: json['deadline']?.toString(),
      createdBy: json['created_by']?.toString(),
      createdAt: json['created_at']?.toString() ?? '',
      updatedAt: json['updated_at']?.toString() ?? '',
      taskFiles: (json['task_files'] as List<dynamic>?)
              ?.map((f) => TaskFile.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
      submission: json['submission'] != null
          ? StudentSubmission.fromJson(json['submission'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'group_name': groupName,
      'subject': subject,
      'title': title,
      'lesson_type': lessonType,
      'lesson_num': lessonNum,
      'lesson_date': lessonDate,
      'description': description,
      'deadline': deadline,
      'created_by': createdBy,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'task_files': taskFiles.map((f) => f.toJson()).toList(),
      'submission': submission?.toJson(),
    };
  }

  TaskStatus get currentStatus => submission?.status ?? TaskStatus.todo;
}
