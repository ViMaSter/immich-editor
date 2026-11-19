import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/editor_photos/ui/editor_actions.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';

final _editableProvider = Provider.family.autoDispose<RemoteAsset?, ActionSource>(
  (ref, source) => ref.watch(ownedAssetsActionProvider(source)).where((asset) => asset.isImage).singleOrNull,
  dependencies: [ownedAssetsActionProvider],
);

/// "Edit" in the asset viewer: opens the editor.photos editor. A long press opens
/// Immich's own editor when the server supports it.
class EditorPhotosEditAction extends AssetActionBuilder {
  const EditorPhotosEditAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(_editableProvider(source));
    if (asset == null) {
      return null;
    }
    final immichEditor = EditAssetAction(source: source).create(context, ref);
    return ActionItem(
      icon: Icons.tune,
      label: 'Edit',
      onAction: () => openEditorPhotos(context, ref, asset.id),
      onSecondaryAction: immichEditor?.onAction,
    );
  }
}
