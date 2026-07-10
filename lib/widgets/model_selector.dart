import 'package:flutter/material.dart';

class ModelSelector extends StatelessWidget {
  final String currentModel;
  final ValueChanged<String> onChanged;
  final List<String> models;

  const ModelSelector({
    super.key,
    required this.currentModel,
    required this.onChanged,
    this.models = const [
      'gpt-4o',
      'gpt-4o-mini',
      'claude-sonnet-5',
      'claude-haiku-4-5',
      'custom',
    ],
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      initialValue: currentModel,
      onSelected: onChanged,
      child: Chip(
        avatar: const Icon(Icons.auto_awesome, size: 16),
        label: Text(currentModel, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
      ),
      itemBuilder: (context) => models.map((model) {
        return PopupMenuItem(
          value: model,
          child: Row(
            children: [
              Icon(
                model == currentModel ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(model),
            ],
          ),
        );
      }).toList(),
    );
  }
}
