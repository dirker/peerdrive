#!/usr/bin/env python
# vim: set fileencoding=utf-8 :
#
# Hotchpotch
# Copyright (C) 2010  Jan Klötzke <jan DOT kloetzke AT freenet DOT de>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

from __future__ import with_statement

from PyQt4 import QtCore, QtGui
from hotchpotch import HpConnector, HpRegistry, hpstruct, hpgui

def extractMetaData(metaData, path, default):
	item = metaData
	for step in path:
		if step in item:
			item = item[step]
		else:
			return default
	return item


def setMetaData(metaData, field, value):
	item = metaData
	path = field[:]
	while len(path) > 1:
		if path[0] not in item:
			item[path[0]] = { }
		item = item[path[0]]
		path = path[1:]
	item[path[0]] = value


buttons = []

def genStoreButton(store):
	b = hpgui.DocButton(store, True)
	buttons.append(b)
	button = b.getWidget()
	return button

def genRevButton(rev):
	b = hpgui.RevButton(rev, True)
	buttons.append(b)
	button = b.getWidget()
	return button

class PropertiesDialog(QtGui.QDialog):
	def __init__(self, guid, isUuid, parent=None):
		super(PropertiesDialog, self).__init__(parent)

		mainLayout = QtGui.QVBoxLayout()
		mainLayout.setSizeConstraint(QtGui.QLayout.SetFixedSize)

		if isUuid:
			self.uuid = guid
			info = HpConnector().lookup(guid)
			mainLayout.addWidget(DocumentTab(info.stores(), "document"))
			self.revs = info.revs()
		else:
			self.uuid = None
			info = HpConnector().stat(guid)
			mainLayout.addWidget(DocumentTab(info.volumes(), "revision"))
			self.revs = [guid]

		if len(self.revs) == 0:
			QtGui.QMessageBox.warning(self, 'Missing document', 'The requested document was not found on any store.')
			sys.exit(1)

		tabWidget = QtGui.QTabWidget()
		self.annoTab = AnnotationTab(self.revs, isUuid and (len(self.revs) == 1))
		QtCore.QObject.connect(self.annoTab, QtCore.SIGNAL("changed()"), self.__changed)
		tabWidget.addTab(self.annoTab, "Annotation")
		tabWidget.addTab(HistoryTab(self.revs), "History")
		if isUuid:
			tabWidget.addTab(RevisionTab(self.revs), "Revisions")
		else:
			tabWidget.addTab(RevisionTab(self.revs), "Revision")
		mainLayout.addWidget(tabWidget)

		if isUuid and (len(self.revs) == 1):
			self.buttonBox = QtGui.QDialogButtonBox(
				QtGui.QDialogButtonBox.Save |
				QtGui.QDialogButtonBox.Close)
			self.buttonBox.button(QtGui.QDialogButtonBox.Save).setEnabled(False)
		else:
			self.buttonBox = QtGui.QDialogButtonBox(QtGui.QDialogButtonBox.Ok)
		QtCore.QObject.connect(self.buttonBox, QtCore.SIGNAL("accepted()"), self.__save)
		QtCore.QObject.connect(self.buttonBox, QtCore.SIGNAL("rejected()"), self.reject)
		mainLayout.addWidget(self.buttonBox)
		self.setLayout(mainLayout)
		self.setWindowTitle("Properties of %s" % (self.annoTab.getTitle()))

	def __changed(self):
		self.buttonBox.button(QtGui.QDialogButtonBox.Save).setEnabled(True)

	def __save(self):
		rev = self.revs[0]
		self.buttonBox.button(QtGui.QDialogButtonBox.Save).setEnabled(False)
		with HpConnector().read(rev) as r:
			metaData = hpstruct.loads(r.readAll('META'))
		setMetaData(metaData, ["org.hotchpotch.annotation", "title"], str(self.annoTab.titleEdit.text()))
		setMetaData(metaData, ["org.hotchpotch.annotation", "description"], str(self.annoTab.descEdit.text()))
		if self.annoTab.tagsEdit.hasAcceptableInput():
			tagString = self.annoTab.tagsEdit.text()
			tagSet = set([ tag.strip() for tag in str(tagString).split(',')])
			tagList = list(tagSet)
			setMetaData(metaData, ["org.hotchpotch.annotation", "tags"], tagList)
		with HpConnector().update(self.uuid, rev) as writer:
			writer.writeAll('META', hpstruct.dumps(metaData))
			self.revs[0] = writer.commit()


class DocumentTab(QtGui.QWidget):
	def __init__(self, stores, descr, parent=None):
		super(DocumentTab, self).__init__(parent)

		mainLayout = QtGui.QVBoxLayout()
		mainLayout.addWidget(QtGui.QLabel("The "+descr+" exists on the following stores:"))
		subLayout = QtGui.QHBoxLayout()
		for store in stores:
			subLayout.addWidget(genStoreButton(store))
		subLayout.addStretch()
		mainLayout.addLayout(subLayout)
		self.setLayout(mainLayout)


class RevisionTab(QtGui.QWidget):
	def __init__(self, revs, parent=None):
		super(RevisionTab, self).__init__(parent)

		layout = QtGui.QGridLayout()
		layout.addWidget(QtGui.QLabel("Type:"), 1, 0)
		layout.addWidget(QtGui.QLabel("Modification time:"), 2, 0)
		layout.addWidget(QtGui.QLabel("Size:"), 3, 0)
		layout.addWidget(QtGui.QLabel("Stores:"), 4, 0)

		col = 1
		for rev in revs:
			stat = HpConnector().stat(rev)

			layout.addWidget(genRevButton(rev), 0, col)
			layout.addWidget(QtGui.QLabel(HpRegistry().getDisplayString(stat.uti())), 1, col)
			layout.addWidget(QtGui.QLabel(str(stat.mtime())), 2, col)
			size = 0
			for part in stat.parts():
				size += stat.size(part)
			for unit in ['Bytes', 'KiB', 'MiB', 'GiB']:
				if size < (1 << 10):
					break
				else:
					size = size >> 10
			sizeText = "%d %s (%d parts)" % (size, unit, len(stat.parts()))
			layout.addWidget(QtGui.QLabel(sizeText), 3, col)

			storeLayout = QtGui.QVBoxLayout()
			for store in stat.volumes():
				storeLayout.addWidget(genStoreButton(store))
			layout.addLayout(storeLayout, 4, col)

			col += 1

		self.setLayout(layout)


class HistoryTab(QtGui.QWidget):
	def __init__(self, revs, parent=None):
		super(HistoryTab, self).__init__(parent)

		# TODO: implement something nice gitk like...
		self.__historyList = []
		self.__historyRevs = []
		heads = revs[:]
		while len(heads) > 0:
			newHeads = []
			for rev in heads:
				try:
					if rev not in self.__historyRevs:
						stat = HpConnector().stat(rev)
						mtime = str(stat.mtime())
						comment = ""
						if 'META' in stat.parts():
							try:
								with HpConnector().read(rev) as r:
									metaData = hpstruct.loads(r.readAll('META'))
									comment = extractMetaData(
										metaData,
										["org.hotchpotch.annotation", "comment"],
										"")
							except IOError:
								pass
						self.__historyList.append(mtime + " - " + comment)
						self.__historyRevs.append(rev)
						newHeads.extend(stat.parents())
				except IOError:
					pass
			heads = newHeads

		self.__historyListBox = QtGui.QListWidget()
		self.__historyListBox.setSizePolicy(
			QtGui.QSizePolicy.Ignored,
			QtGui.QSizePolicy.Ignored )
		self.__historyListBox.insertItems(0, self.__historyList)
		QtCore.QObject.connect(
			self.__historyListBox,
			QtCore.SIGNAL("itemDoubleClicked(QListWidgetItem *)"),
			self.__open)

		layout = QtGui.QVBoxLayout()
		layout.addWidget(self.__historyListBox)
		self.setLayout(layout)

	def __open(self, item):
		row = self.__historyListBox.row(item)
		rev = self.__historyRevs[row]
		hpgui.showDocument(hpstruct.RevLink(rev))


class AnnotationTab(QtGui.QWidget):
	def __init__(self, revs, edit, parent=None):
		super(AnnotationTab, self).__init__(parent)

		titles = set()
		self.__title = ""
		descriptions = set()
		description = ""
		tagSets = set()
		tags = []
		for rev in revs:
			try:
				with HpConnector().read(rev) as r:
					metaData = hpstruct.loads(r.readAll('META'))
					self.__title = extractMetaData(
						metaData,
						["org.hotchpotch.annotation", "title"],
						"")
					titles.add(self.__title)
					description = extractMetaData(
						metaData,
						["org.hotchpotch.annotation", "description"],
						"")
					descriptions.add(description)
					tags = extractMetaData(
						metaData,
						["org.hotchpotch.annotation", "tags"],
						[])
					tagSets.add(frozenset(tags))
			except IOError:
				pass

		layout = QtGui.QGridLayout()

		layout.addWidget(QtGui.QLabel("Title:"), 0, 0)
		if len(titles) > 1:
			layout.addWidget(QtGui.QLabel("<ambiguous>"), 0, 1)
		else:
			if edit:
				self.titleEdit = QtGui.QLineEdit()
				self.titleEdit.setText(self.__title)
				QtCore.QObject.connect(self.titleEdit, QtCore.SIGNAL("textEdited(const QString&)"), self.__changed)
				layout.addWidget(self.titleEdit, 0, 1)
			else:
				layout.addWidget(QtGui.QLabel(self.__title), 0, 1)

		layout.addWidget(QtGui.QLabel("Description:"), 1, 0)
		if len(descriptions) > 1:
			layout.addWidget(QtGui.QLabel("<ambiguous>"), 1, 1)
		else:
			if edit:
				self.descEdit = QtGui.QLineEdit()
				self.descEdit.setText(description)
				QtCore.QObject.connect(self.descEdit, QtCore.SIGNAL("textEdited(const QString&)"), self.__changed)
				layout.addWidget(self.descEdit, 1, 1)
			else:
				descLabel = QtGui.QLabel(description)
				descLabel.setWordWrap(True)
				descLabel.setScaledContents(True)
				layout.addWidget(descLabel, 1, 1)

		layout.addWidget(QtGui.QLabel("Tags:"), 2, 0)
		if len(tagSets) > 1:
			layout.addWidget(QtGui.QLabel("<ambiguous>"), 2, 1)
		else:
			tags.sort()
			tagList = ""
			for tag in tags:
				tagList += ", " + tag
			if edit:
				self.tagsEdit = QtGui.QLineEdit()
				self.tagsEdit.setText(tagList[2:])
				self.tagsEdit.setValidator(QtGui.QRegExpValidator(
					QtCore.QRegExp("(\\s*\\w+\\s*(,\\s*\\w+\\s*)*)?"),
					self))
				QtCore.QObject.connect(self.tagsEdit, QtCore.SIGNAL("textEdited(const QString&)"), self.__changed)
				layout.addWidget(self.tagsEdit, 2, 1)
			else:
				layout.addWidget(QtGui.QLabel(tagList[2:]), 2, 1)

		self.setLayout(layout)

	def getTitle(self):
		return self.__title

	def __changed(self):
		self.emit(QtCore.SIGNAL("changed()"))


if __name__ == '__main__':

	import sys

	app = QtGui.QApplication(sys.argv)

	if (len(sys.argv) == 2) and sys.argv[1].startswith('doc:'):
		guid = sys.argv[1][4:].decode('hex')
		dialog = PropertiesDialog(guid, True)
	elif (len(sys.argv) == 2) and sys.argv[1].startswith('rev:'):
		guid = sys.argv[1][4:].decode('hex')
		dialog = PropertiesDialog(guid, False)
	else:
		print "Usage: properties.py [uuid:|rev:]GUID"
		sys.exit(1)

	sys.exit(dialog.exec_())

