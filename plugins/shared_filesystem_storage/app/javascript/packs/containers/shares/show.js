import { connect } from  'react-redux';
import ShowShareModal from '../../components/shares/show';
import { fetchShareExportLocationsIfNeeded } from '../../actions/shares';
import { fetchShareTypesIfNeeded } from '../../actions/share_types';

export default connect(
  (state,ownProps ) => {
    let share;
    let match = ownProps.match
    if (match && match.params && match.params.id) {
      let shares = state.shared_filesystem_storage.shares.items
      if (shares) share = shares.find(item => item.id==match.params.id)
    }

    return { share, shareTypes: state.shared_filesystem_storage.shareTypes }
  },
  dispatch => ({
    loadExportLocationsOnce: (shareId) => dispatch(fetchShareExportLocationsIfNeeded(shareId)),
    loadShareTypesOnce: () => dispatch(fetchShareTypesIfNeeded())
  })
)(ShowShareModal);
